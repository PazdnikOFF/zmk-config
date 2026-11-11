import AppKit
import UserNotifications

/*
 * Диктовка через колонку Jarvis: клавиша → колонка слушает → текст в поле.
 *
 * Поведение повторяет Handy (cjpais/Handy):
 *   - режимы «удерживать» и «нажать — начать, нажать — закончить»;
 *   - звук начала и красная точка — только когда колонка реально слушает
 *     (событие listening), а не по нажатию; звук конца — по отпусканию;
 *   - Esc отменяет запись и действует только пока она идёт;
 *   - нажатие во время распознавания запоминается и начинает новую запись
 *     сразу после вставки; второе такое нажатие запоминание снимает.
 * Отличие владельца: нажатие короче 0,4 с в режиме удержания — отмена.
 *
 * Ввод «сразу»: каждый segment вставляется по мере прихода. После stop
 * вставляется остаток: text минус уже вставленное начало. Это то же, что
 * «дождаться segment с i < emitted и вставить tail» (text = все отрезки подряд),
 * но без ожидания событий, которые ещё в пути по второму соединению.
 */

var dictationController: DictationController?

final class DictationController {
    enum Indicator { case idle, recording, transcribing }

    fileprivate final class Run {
        let number: Int
        let t0: TimeInterval
        let trigger: DictationTrigger
        let insert: DictationInsert
        let targetPID: pid_t
        let targetName: String
        let delivery: DictationDelivery

        var sid: String?
        var keyDown = true
        var released = false
        var stopping = false
        var stopReplied = false
        var tListening: TimeInterval?
        var tRelease: TimeInterval?
        var tStopReply: TimeInterval?
        var segments: [Int: String] = [:]
        var nextSegment = 0
        var segmentsInserted = 0
        var insertedPrefix = ""
        var phraseText = ""
        var finalText = ""
        var brokerMs: [String: Int] = [:]
        var levels: [Double] = []

        init(number: Int, t0: TimeInterval, settings: DictationSettings, target: NSRunningApplication?,
             clock: @escaping () -> TimeInterval) {
            self.number = number
            self.t0 = t0
            trigger = settings.trigger
            insert = settings.insert
            targetPID = target?.processIdentifier ?? -1
            targetName = target?.localizedName ?? "?"
            delivery = DictationDelivery(targetPID: targetPID, method: settings.pasteMethod, clock: clock)
        }
    }

    static let shortPress: TimeInterval = 0.4
    static let debounce: TimeInterval = 0.03

    private static let mainHotkeyID: UInt32 = 1
    private static let escapeHotkeyID: UInt32 = 2
    private static let escapeHotkey = DictationHotkey(keyCode: 53, modifiers: 0)

    private let settings = DictationSettings.shared
    private let broker = DictationBroker()
    private let island = DictationIsland()
    private weak var menuBar: MenuBarController?

    private var run: Run?
    private var runCounter = 0
    private var lastPress: TimeInterval = 0
    private var queuedPress = false
    private var suspended = false
    private var registered: DictationHotkey?
    private var askedNotifications = false

    private(set) var indicator: Indicator = .idle

    var isActive: Bool { run != nil }

    init(menuBar: MenuBarController?) {
        self.menuBar = menuBar
        island.onCancel = { [weak self] in self?.cancelCurrent(reason: "кнопка отмены") }
        settings.importTokenFileIfPresent()
        settings.onChange = { [weak self] in self?.applySettings() }
        DictationSounds.prepare()
        DictationVolume.recoverAfterCrash()
        DictationLog.write("готова, журнал \(DictationLog.url.path)")
        applySettings()
    }

    private func clock() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: - Клавиши

    /// Перерегистрировать клавишу, если что-то в настройках её касается.
    func applySettings() {
        let wanted: DictationHotkey? =
            settings.enabled && settings.isConfigured && !suspended ? settings.hotkey : nil
        guard wanted != registered else { return }

        DictationHotkeys.shared.unregister(id: DictationController.mainHotkeyID)
        registered = nil
        guard let wanted else {
            if !suspended { settings.hotkeyProblem = nil }
            return
        }

        let ok = DictationHotkeys.shared.register(
            id: DictationController.mainHotkeyID, hotkey: wanted,
            handlers: .init(
                pressed: { [weak self] in self?.hotkeyPressed() },
                released: { [weak self] in self?.hotkeyReleased() }))
        if ok {
            registered = wanted
            settings.hotkeyProblem = nil
            DictationLog.write("клавиша \(wanted.title), режим \(settings.trigger.rawValue)")
        } else {
            settings.hotkeyProblem = "Сочетание \(wanted.title) занято другой программой"
        }
    }

    /// Пока в настройках записывают новое сочетание, старое не должно срабатывать.
    func suspendHotkey(_ suspend: Bool) {
        suspended = suspend
        applySettings()
    }

    private func setEscape(_ on: Bool) {
        if on {
            DictationHotkeys.shared.register(
                id: DictationController.escapeHotkeyID, hotkey: DictationController.escapeHotkey,
                handlers: .init(
                    pressed: { [weak self] in self?.escapePressed() },
                    released: {}))
        } else {
            DictationHotkeys.shared.unregister(id: DictationController.escapeHotkeyID)
        }
    }

    private func hotkeyPressed() {
        let now = clock()
        guard now - lastPress > DictationController.debounce else { return }
        lastPress = now

        guard let run else {
            begin()
            return
        }
        run.keyDown = true
        if !run.released {
            if run.trigger == .toggle { release(run) }
            // при удержании повторное нажатие без отпускания — автоповтор, игнорируем
            return
        }
        // Идёт распознавание или вставка — запомнить нажатие, как Handy.
        queuedPress.toggle()
        DictationLog.write(run, at: now, queuedPress ? "нажатие запомнено до конца вставки" : "запомненное нажатие снято")
    }

    private func hotkeyReleased() {
        guard let run else { return }
        run.keyDown = false
        if run.trigger == .hold, !run.released { release(run) }
    }

    private func escapePressed() {
        guard let run, !run.released else { return }
        cancelCurrent(reason: "Esc")
    }

    // MARK: - Ход диктовки

    private func begin() {
        guard settings.enabled else { return }
        guard settings.isConfigured else {
            island.showNotice(DictationBroker.Failure.notConfigured.message)
            return
        }

        runCounter += 1
        let target = NSWorkspace.shared.frontmostApplication
        let run = Run(number: runCounter, t0: clock(), settings: settings, target: target, clock: clock)
        run.delivery.hotkeyHeld = { [weak run] in run?.keyDown ?? false }
        self.run = run

        setEscape(true)
        /*
         * На Mac играет звук (ролик, музыка): микрофон колонки его слышит. Тогда
         * приглушаем сразу при нажатии и не берём звук до нажатия — иначе в текст
         * попадает конец ролика. Звук начала при этом не слышен, но сигналом
         * служит сам затихший звук и «Говорите» в островке.
         * Тихо — приглушаем после звука начала, запас до нажатия — 400 мс.
         */
        let mediaPlaying = DictationVolume.outputIsRunning()
        if settings.duckVolume && (mediaPlaying || !settings.sounds) { DictationVolume.duck() }
        let preMs = mediaPlaying ? 0 : 400
        island.showRecording()
        askNotificationsOnce()
        DictationLog.write(
            run, at: run.t0,
            "нажатие · \(run.targetName) · \(run.trigger.rawValue) · \(run.insert.rawValue) · \(settings.pasteMethod.rawValue)"
                + (mediaPlaying ? " · на Mac играет звук: запас до нажатия 0" : ""))

        broker.start(preMs: preMs) { [weak self] result in self?.started(run, result) }
    }

    private func started(_ run: Run, _ result: Result<String, DictationBroker.Failure>) {
        let now = clock()
        guard self.run === run else {
            // Отменили, пока ждали ответа: сессию на брокере закрыть.
            if case .success(let sid) = result { broker.cancel(sid: sid) }
            return
        }

        switch result {
        case .success(let sid):
            run.sid = sid
            DictationLog.write(run, at: now, "start → \(sid)")
            broker.openEvents(sid: sid) { [weak self] event in self?.handle(event, run) }
            if run.released { sendStop(run) }
        case .failure(let failure):
            DictationLog.write(run, at: now, "start не удался: \(failure.code)")
            finish(run, notice: failure.message)
        }
    }

    private func handle(_ event: DictationBroker.Event, _ run: Run) {
        guard self.run === run else { return }

        switch event {
        case .state("listening"):
            guard run.tListening == nil else { return }
            let now = clock()
            run.tListening = now
            DictationLog.write(run, at: now, "колонка слушает")
            guard !run.released else { return }
            DictationSounds.playStart()
            if settings.duckVolume && settings.sounds {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self, weak run] in
                    guard let self, let run, self.run === run, !run.released else { return }
                    DictationVolume.duck()
                }
            }
            island.setListening()
            setIndicator(.recording)

        case .state("error"):
            guard !run.stopping else { return }
            DictationLog.write(run, at: clock(), "брокер прервал запись")
            finish(run, notice: "Запись прервана")

        case .state:
            break

        case .level(let db):
            if run.levels.count < 6000 { run.levels.append(db) }  // 5 минут
            island.level(db)

        case .closed(let reason):
            DictationLog.write(run, at: clock(), "поток событий закрыт: \(reason)")
            // Колонка так и не начала слушать — ждать нечего. Иначе текст всё равно
            // придёт ответом stop: в режиме «сразу» вставится всё, что не успело.
            if run.tListening == nil, !run.stopping {
                cancelCurrent(reason: nil)
                island.showNotice("Нет связи с брокером")
            }

        case .segment(let index, let text):
            guard !run.stopReplied else { return }
            run.segments[index] = text
            while let piece = run.segments.removeValue(forKey: run.nextSegment) {
                run.nextSegment += 1
                switch run.insert {
                case .live:
                    run.insertedPrefix += piece
                    run.segmentsInserted += 1
                    if run.segmentsInserted == 1 {
                        DictationLog.write(run, at: clock(), "первый отрезок → вставка")
                    }
                    run.delivery.enqueue(piece)
                case .phrase:
                    run.phraseText += piece
                    island.setTranscript(run.phraseText)
                }
            }
        }
    }

    private func release(_ run: Run) {
        let now = clock()
        run.released = true
        run.tRelease = now

        if run.trigger == .hold, now - run.t0 < DictationController.shortPress {
            DictationLog.write(run, at: now, "отпускание через \(ms(now - run.t0)) мс — короткое, отмена")
            cancelCurrent(reason: nil)
            return
        }

        DictationLog.write(run, at: now, "отпускание")
        setEscape(false)
        DictationVolume.restore()
        if run.tListening != nil { DictationSounds.playStop() }
        island.showTranscribing()
        setIndicator(.transcribing)
        if run.sid != nil { sendStop(run) }
    }

    private func sendStop(_ run: Run) {
        guard let sid = run.sid, !run.stopping else { return }
        run.stopping = true
        broker.stop(sid: sid) { [weak self] result in self?.stopped(run, result) }
    }

    private func stopped(_ run: Run, _ result: Result<DictationBroker.StopResult, DictationBroker.Failure>) {
        guard self.run === run else { return }
        let now = clock()
        run.tStopReply = now
        run.stopReplied = true
        broker.closeEvents()

        switch result {
        case .success(let reply):
            run.brokerMs = reply.brokerMs
            run.finalText = reply.text
            let sinceRelease = run.tRelease.map { ms(now - $0) } ?? 0
            DictationLog.write(
                run, at: now,
                "ответ stop через \(sinceRelease) мс после отпускания · emitted \(reply.emitted), у нас \(run.segmentsInserted) · хвост \(reply.tail.count) симв.")

            switch run.insert {
            case .live:
                if reply.text.hasPrefix(run.insertedPrefix) {
                    run.delivery.enqueue(String(reply.text.dropFirst(run.insertedPrefix.count)))
                } else {
                    DictationLog.write(run, at: now, "вставленное начало не совпало с text — вставляю tail")
                    run.delivery.enqueue(reply.tail)
                }
            case .phrase:
                island.setTranscript(reply.text)
                run.delivery.enqueue(reply.text)
            }
            run.delivery.finish { [weak self] report in self?.delivered(run, report, error: nil) }

        case .failure(let failure):
            DictationLog.write(run, at: now, "stop не удался: \(failure.code)")
            run.delivery.finish { [weak self] report in self?.delivered(run, report, error: failure.message) }
        }
    }

    private func delivered(_ run: Run, _ report: DictationDelivery.Report, error: String?) {
        guard self.run === run else { return }
        let now = clock()

        func rel(_ t: TimeInterval?) -> String { t.map { "\(ms($0 - run.t0))" } ?? "—" }
        let pasteAfterRelease = both(report.lastPaste, run.tRelease).map { "\(ms($0 - $1))" } ?? "—"
        let stopAfterRelease = both(run.tStopReply, run.tRelease).map { "\(ms($0 - $1))" } ?? "—"
        var summary =
            "итог: слушаю \(rel(run.tListening)) · отпускание \(rel(run.tRelease))"
            + " · stop +\(stopAfterRelease) · вставка +\(pasteAfterRelease) после отпускания"
            + " · \(report.pastes) вставок, \(report.pastedChars) симв."
        if !run.levels.isEmpty {
            let sorted = run.levels.sorted()
            let pick = { (q: Double) in Int(sorted[Int(Double(sorted.count - 1) * q)].rounded()) }
            summary += " · уровень дБ: мин \(pick(0)) p10 \(pick(0.1)) медиана \(pick(0.5)) p90 \(pick(0.9)) макс \(pick(1))"
        }
        if let divert = report.divert { summary += " · в буфер \(report.diverted.count) симв. (\(divert.logCode))" }
        if !run.brokerMs.isEmpty {
            let parts = run.brokerMs.sorted { $0.value < $1.value }.map { "\($0.key)=\($0.value)" }
            summary += " · брокер мс: " + parts.joined(separator: " ")
        }
        DictationLog.write(run, at: now, summary)

        if let error {
            finish(run, notice: error)
        } else if let divert = report.divert, !report.diverted.isEmpty {
            notify(divert.message)
            finish(run, notice: divert.message, symbol: "doc.on.clipboard")
        } else {
            finish(run, notice: nil)
        }
    }

    // MARK: - Отмена и завершение

    func cancelCurrent(reason: String?) {
        guard let run else { return }
        if let reason { DictationLog.write(run, at: clock(), "отмена: \(reason)") }
        if let sid = run.sid { broker.cancel(sid: sid) }
        run.delivery.cancel()
        queuedPress = false
        finish(run, notice: nil)
    }

    private func finish(_ run: Run, notice: String?, symbol: String = "exclamationmark.triangle.fill") {
        guard self.run === run else { return }
        self.run = nil
        broker.closeEvents()
        setEscape(false)
        DictationVolume.restore()
        setIndicator(.idle)
        if let notice {
            island.showNotice(notice, symbolName: symbol)
        } else {
            island.hide()
        }
        if queuedPress {
            queuedPress = false
            begin()
        }
    }

    private func setIndicator(_ value: Indicator) {
        indicator = value
        menuBar?.setDictationIndicator(value)
    }

    // MARK: - Уведомления

    private func askNotificationsOnce() {
        guard !askedNotifications else { return }
        askedNotifications = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    private func notify(_ message: String) {
        let content = UNMutableNotificationContent()
        content.title = "Диктовка"
        content.body = message + ". Вставьте его ⌘V."
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { log("диктовка: уведомление не показано — \(error.localizedDescription)") }
        }
    }
}

private func ms(_ seconds: TimeInterval) -> Int { Int((seconds * 1000).rounded()) }

private func both(_ a: TimeInterval?, _ b: TimeInterval?) -> (TimeInterval, TimeInterval)? {
    guard let a, let b else { return nil }
    return (a, b)
}

/*
 * Журнал диктовки: ~/Library/Logs/SweepDongleAgent/dictation.log (открывается в
 * Console.app). Времена — от нажатия клавиши, в мс. Токен сюда не попадает.
 */
enum DictationLog {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/SweepDongleAgent/dictation.log")

    private static let maxBytes = 1 << 20

    private static let handle: FileHandle? = {
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxBytes {
            let old = url.appendingPathExtension("1")
            try? manager.removeItem(at: old)
            try? manager.moveItem(at: url, to: old)
        }
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        return handle
    }()

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    static func write(_ message: String) {
        log("диктовка: \(message)")
        let line = "\(stamp.string(from: Date())) \(message)\n"
        try? handle?.write(contentsOf: Data(line.utf8))
    }

    fileprivate static func write(_ run: DictationController.Run, at time: TimeInterval, _ message: String) {
        write("#\(run.number) +\(ms(time - run.t0)) мс \(message)")
    }
}
