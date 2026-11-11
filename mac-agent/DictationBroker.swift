import Foundation

/*
 * Клиент брокера диктовки на GMKtec (server/dictate_server.py колонки).
 *
 *   POST /dictate/start           → {sid} | 409 busy | 503 offline
 *   GET  /dictate/<sid>/events    → SSE: state, level {db}, segment {i, text}
 *   POST /dictate/<sid>/stop      → {tail, emitted, text, ms}
 *   POST /dictate/<sid>/cancel
 *
 * Все колбэки приходят на главный поток. Две сессии URLSession: короткие
 * запросы — с completion handler, поток событий — через делегат, чтобы читать
 * SSE по мере прихода байтов.
 */
final class DictationBroker: NSObject, URLSessionDataDelegate {
    enum Failure: Error {
        case busy, offline, timeout, unauthorized, notConfigured
        case other(String)

        var message: String {
            switch self {
            case .busy: return "Колонка занята"
            case .offline: return "Колонка не в сети"
            case .timeout: return "Брокер не ответил"
            case .unauthorized: return "Брокер не принял токен"
            case .notConfigured: return "Задайте адрес брокера и токен"
            case .other(let text): return text
            }
        }

        var code: String {
            switch self {
            case .busy: return "busy"
            case .offline: return "offline"
            case .timeout: return "timeout"
            case .unauthorized: return "401"
            case .notConfigured: return "not_configured"
            case .other(let text): return text
            }
        }
    }

    struct StopResult {
        var tail: String
        var emitted: Int
        var text: String
        var brokerMs: [String: Int]
    }

    enum Event {
        case state(String)
        case level(Double)
        case segment(Int, String)
        /// Поток событий закрылся не по нашей воле: код ответа или текст ошибки.
        case closed(String)
    }

    static let startTimeout: TimeInterval = 1.5
    private static let separator = Data("\n\n".utf8)

    private let settings = DictationSettings.shared

    private lazy var rpc: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 4
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private lazy var stream: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 40  // брокер шлёт ": ping" раз в 15 с
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    private var eventsTask: URLSessionDataTask?
    private var eventsSid: String?
    private var onEvent: ((Event) -> Void)?
    private var pending = Data()

    // MARK: - Короткие запросы

    private func request(_ path: String, timeout: TimeInterval) -> URLRequest? {
        guard let base = settings.brokerURL, !settings.token.isEmpty else { return nil }
        var request = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(settings.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func post(
        _ path: String, timeout: TimeInterval,
        completion: @escaping (Result<[String: Any], Failure>) -> Void
    ) {
        guard let request = request(path, timeout: timeout) else {
            completion(.failure(.notConfigured))
            return
        }
        rpc.dataTask(with: request) { data, response, error in
            let result: Result<[String: Any], Failure>
            if let error = error as? URLError {
                result = .failure(error.code == .timedOut ? .timeout : .other(error.localizedDescription))
            } else if let error {
                result = .failure(.other(error.localizedDescription))
            } else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let body =
                    (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
                switch status {
                case 200..<300: result = .success(body)
                case 401, 403: result = .failure(.unauthorized)
                case 409: result = .failure(.busy)
                case 503: result = .failure(.offline)
                default:
                    result = .failure(.other("Брокер ответил \(status) \(body["error"] as? String ?? "")"))
                }
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    func start(completion: @escaping (Result<String, Failure>) -> Void) {
        post("dictate/start", timeout: DictationBroker.startTimeout) { result in
            switch result {
            case .success(let body):
                if let sid = body["sid"] as? String, !sid.isEmpty {
                    completion(.success(sid))
                } else {
                    completion(.failure(.other("Брокер не выдал sid")))
                }
            case .failure(let failure):
                completion(.failure(failure))
            }
        }
    }

    func stop(sid: String, completion: @escaping (Result<StopResult, Failure>) -> Void) {
        // Брокер ждёт звук до момента отпускания не дольше 1,5 с плюс распознавание хвоста.
        post("dictate/\(sid)/stop", timeout: 10) { result in
            completion(
                result.map { body in
                    StopResult(
                        tail: body["tail"] as? String ?? "",
                        emitted: body["emitted"] as? Int ?? 0,
                        text: body["text"] as? String ?? "",
                        brokerMs: body["ms"] as? [String: Int] ?? [:])
                })
        }
    }

    func cancel(sid: String) {
        post("dictate/\(sid)/cancel", timeout: 3) { result in
            if case .failure(let failure) = result {
                log("диктовка: cancel \(sid) — \(failure.code)")
            }
        }
    }

    /// Проверка из настроек: доступен ли адрес. Колонку не будит.
    func health(completion: @escaping (Result<Void, Failure>) -> Void) {
        guard let base = settings.brokerURL else {
            completion(.failure(.notConfigured))
            return
        }
        let request = URLRequest(url: base.appendingPathComponent("dictate/health"), timeoutInterval: 3)
        rpc.dataTask(with: request) { _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let result: Result<Void, Failure> =
                error == nil && status == 200
                ? .success(()) : .failure(.other(error?.localizedDescription ?? "ответ \(status)"))
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    // MARK: - Поток событий

    func openEvents(sid: String, onEvent: @escaping (Event) -> Void) {
        closeEvents()
        guard let base = settings.brokerURL, !settings.token.isEmpty else { return }

        var request = URLRequest(url: base.appendingPathComponent("dictate/\(sid)/events"))
        request.setValue("Bearer \(settings.token)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        self.onEvent = onEvent
        eventsSid = sid
        pending.removeAll(keepingCapacity: true)
        let task = stream.dataTask(with: request)
        eventsTask = task
        task.resume()
    }

    func closeEvents() {
        eventsTask?.cancel()
        eventsTask = nil
        eventsSid = nil
        onEvent = nil
        pending.removeAll()
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard dataTask === eventsTask else {
            completionHandler(.cancel)
            return
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            completionHandler(.cancel)
            let notify = onEvent
            eventsTask = nil
            notify?(.closed("ответ \(status)"))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard dataTask === eventsTask else { return }
        // CR выбрасываем: тогда разделитель событий всегда «\n\n», в том числе за прокси.
        pending.append(contentsOf: data.filter { $0 != 0x0D })
        parsePending()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === eventsTask else { return }
        eventsTask = nil
        if (error as? URLError)?.code == .cancelled { return }
        let reason = error?.localizedDescription ?? "брокер закрыл поток"
        onEvent?(.closed(reason))
    }

    /// Разбор SSE: события разделены пустой строкой, поля «event:» и «data:».
    private func parsePending() {
        while let range = pending.range(of: DictationBroker.separator) {
            let block = pending.subdata(in: pending.startIndex..<range.lowerBound)
            pending.removeSubrange(pending.startIndex..<range.upperBound)
            guard let text = String(data: block, encoding: .utf8) else { continue }

            var name = "message"
            var payload = ""
            for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
                let line = rawLine.hasSuffix("\r") ? rawLine.dropLast() : rawLine
                if line.hasPrefix(":") { continue }  // ping
                if line.hasPrefix("event:") {
                    name = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("data:") {
                    payload += line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                }
            }
            guard !payload.isEmpty,
                let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
            else { continue }

            switch name {
            case "state":
                if let value = object["value"] as? String { onEvent?(.state(value)) }
            case "level":
                if let db = (object["db"] as? NSNumber)?.doubleValue { onEvent?(.level(db)) }
            case "segment":
                if let index = object["i"] as? Int, let text = object["text"] as? String {
                    onEvent?(.segment(index, text))
                }
            default:
                break
            }
        }
    }
}
