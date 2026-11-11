import AppKit
import ApplicationServices
import SwiftUI

/*
 * Окно «Диктовка»: настройки по HIG — сгруппированная форма, одна панель,
 * кнопки свернуть/развернуть погашены, открывается пунктом «Настройки диктовки…»
 * (⌘,) в меню значка.
 */
final class DictationSettingsWindow: NSObject, NSWindowDelegate {
    static let shared = DictationSettingsWindow()

    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: DictationSettingsView())
            let window = NSWindow(contentViewController: hosting)
            window.title = "Диктовка"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        HotkeyRecorderModel.shared.stop()
    }

    /// Окно ушло на задний план посреди записи сочетания — старую клавишу вернуть.
    func windowDidResignKey(_ notification: Notification) {
        HotkeyRecorderModel.shared.stop()
    }
}

/// Запись нового сочетания: ловим keyDown в своём окне, старую клавишу на время глушим.
final class HotkeyRecorderModel: ObservableObject {
    static let shared = HotkeyRecorderModel()

    @Published var recording = false
    @Published var hint: String?
    private var monitor: Any?

    func start() {
        guard !recording else { return }
        recording = true
        hint = "Нажмите сочетание. Esc — отмена"
        dictationController?.suspendHotkey(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
            return nil
        }
    }

    func stop() {
        guard recording else { return }
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        dictationController?.suspendHotkey(false)
    }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let code = UInt32(event.keyCode)

        if code == 53, flags.isEmpty {
            hint = nil
            stop()
            return
        }

        let candidate = DictationHotkey(keyCode: code, modifiers: DictationHotkey.carbonModifiers(flags))
        let strong = !flags.intersection([.command, .option, .control]).isEmpty
        guard strong || candidate.isFunctionKey else {
            hint = "Нужен ⌘, ⌥ или ⌃ — или функциональная клавиша F1–F20"
            return
        }

        hint = nil
        DictationSettings.shared.hotkey = candidate
        stop()
    }
}

/*
 * Состояние окна — в ObservableObject, а не в @State: в SDK 27 @State стал
 * макросом, а плагина SwiftUIMacros в Command Line Tools нет (только в Xcode).
 */
final class DictationSettingsModel: ObservableObject {
    static let shared = DictationSettingsModel()

    @Published var token = DictationSettings.shared.token
    @Published var check: String?
    @Published var checking = false
    @Published var trusted = AXIsProcessTrusted()

    private var tokenSave: DispatchWorkItem?
    private let broker = DictationBroker()

    /*
     * Токен уходит в Keychain не на каждую букву, а после паузы в наборе, по ↩
     * и при закрытии окна: каждая запись — обращение к связке ключей.
     */
    func scheduleTokenSave() {
        tokenSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveToken() }
        tokenSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    func saveToken() {
        tokenSave?.cancel()
        tokenSave = nil
        DictationSettings.shared.token = token
    }

    func runCheck() {
        saveToken()
        checking = true
        check = nil
        broker.health { [weak self] result in
            guard let self else { return }
            self.checking = false
            switch result {
            case .success:
                self.check =
                    DictationSettings.shared.token.isEmpty
                    ? "Брокер доступен, но токен не задан" : "Брокер доступен"
            case .failure(let failure):
                self.check = "Нет связи: \(failure.message)"
            }
        }
    }

    func refreshTrust() { trusted = AXIsProcessTrusted() }
}

struct DictationSettingsView: View {
    @ObservedObject private var settings = DictationSettings.shared
    @ObservedObject private var recorder = HotkeyRecorderModel.shared
    @ObservedObject private var model = DictationSettingsModel.shared

    var body: some View {
        Form {
            Section {
                Toggle("Диктовка через колонку Jarvis", isOn: $settings.enabled)
            } footer: {
                Text("Колонка слушает, брокер на GMKtec распознаёт, текст вставляется в поле с фокусом.")
                    .foregroundStyle(.secondary)
            }

            Section("Клавиша") {
                LabeledContent("Сочетание") {
                    Button(recorder.recording ? "Нажмите сочетание…" : settings.hotkey.title) {
                        recorder.recording ? recorder.stop() : recorder.start()
                    }
                    .accessibilityHint("Нажмите, затем нажмите новое сочетание клавиш")
                }
                if let hint = recorder.hint {
                    Text(hint).font(.callout).foregroundStyle(.secondary)
                }
                if let problem = settings.hotkeyProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Picker("Режим", selection: $settings.trigger) {
                    Text("Удерживать: отпустили — конец").tag(DictationTrigger.hold)
                    Text("Нажать — начать, нажать ещё раз — конец").tag(DictationTrigger.toggle)
                }
                .pickerStyle(.radioGroup)
            }

            Section {
                Picker("Ввод", selection: $settings.insert) {
                    Text("Сразу, по мере распознавания").tag(DictationInsert.live)
                    Text("Всю фразу после окончания").tag(DictationInsert.phrase)
                }
                .pickerStyle(.radioGroup)
                Picker("Способ вставки", selection: $settings.pasteMethod) {
                    Text("Буфер обмена и ⌘V").tag(DictationPasteMethod.clipboard)
                    Text("Набор символами").tag(DictationPasteMethod.typing)
                }
                Toggle("Звуки начала и конца записи", isOn: $settings.sounds)
                Toggle("Приглушать звук Mac во время записи", isOn: $settings.duckVolume)
            } header: {
                Text("Ввод")
            } footer: {
                Text(
                    "Пока зажат аккорд с ⌘, ⌥, ⌃ или ⇧, текст ждёт отпускания модификаторов. "
                        + "Чтобы при удержании текст шёл во время речи, назначьте клавишу без модификаторов, "
                        + "например F18 на Sweep. «Набор символами» — для полей, которые не принимают вставку кусками."
                )
                .foregroundStyle(.secondary)
            }

            Section("Брокер") {
                TextField("Адрес брокера", text: $settings.brokerAddress, prompt: Text(DictationSettings.defaultBroker))
                    .autocorrectionDisabled()
                SecureField("Токен", text: $model.token)
                    .onSubmit(model.saveToken)
                    .onChange(of: model.token) { _, _ in model.scheduleTokenSave() }
                HStack {
                    Button("Проверить связь", action: model.runCheck)
                        .disabled(model.checking || settings.brokerURL == nil)
                    if model.checking { ProgressView().controlSize(.small) }
                    if let check = model.check { Text(check).foregroundStyle(.secondary) }
                }
            }

            Section("Доступ") {
                LabeledContent("Управление устройством") {
                    if model.trusted {
                        Label("Разрешён", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Открыть Системные настройки…", action: openAccessibility)
                    }
                }
                Text("Системные настройки → Конфиденциальность и безопасность → «Управление устройством и доступ к данным» (до macOS 27 — «Универсальный доступ»). Нужно, чтобы вставлять текст нажатием ⌘V в другие программы.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Показать журнал диктовки") {
                    NSWorkspace.shared.activateFileViewerSelecting([DictationLog.url])
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            model.refreshTrust()
        }
        .onDisappear(perform: model.saveToken)
    }

    private func openAccessibility() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
