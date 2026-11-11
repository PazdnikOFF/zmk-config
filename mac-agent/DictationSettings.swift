import AppKit
import Carbon
import Combine
import Security

/*
 * Настройки диктовки через колонку Jarvis (ADR 028 проекта колонки).
 *
 * Всё, кроме токена, лежит в UserDefaults. Токен брокера — в Keychain и
 * читается один раз за запуск: бандл подписан ad-hoc, и после каждой
 * пересборки Keychain заново спрашивает разрешение. С кешем — один вопрос на
 * сборку, а не на каждое нажатие.
 */

/// Как клавиша управляет записью.
enum DictationTrigger: String, CaseIterable {
    /// Зажал — говорю, отпустил — конец.
    case hold
    /// Нажал — начало, нажал ещё раз — конец.
    case toggle
}

/// Когда текст попадает в поле.
enum DictationInsert: String, CaseIterable {
    /// Каждый готовый отрезок вставляется, пока человек ещё говорит.
    case live
    /// Отрезки видны только в островке, в поле — вся фраза после конца.
    case phrase
}

/// Чем текст попадает в поле.
enum DictationPasteMethod: String, CaseIterable {
    /// Буфер обмена и ⌘V — быстро и работает почти везде.
    case clipboard
    /// Набор символами через CGEvent — для полей, которые ⌘V кусками не берут.
    case typing
}

/// Сочетание клавиш в терминах Carbon: код клавиши и маска модификаторов.
struct DictationHotkey: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    /// ⌥Пробел — как у Handy на macOS.
    static let standard = DictationHotkey(keyCode: 49, modifiers: UInt32(optionKey))

    var isChord: Bool { modifiers != 0 }

    var title: String {
        var out = ""
        if modifiers & UInt32(controlKey) != 0 { out += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { out += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { out += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { out += "⌘" }
        return out + DictationHotkey.keyName(keyCode)
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        if flags.contains(.option) { mask |= UInt32(optionKey) }
        if flags.contains(.shift) { mask |= UInt32(shiftKey) }
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        return mask
    }

    static let functionKeys: [UInt32: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]

    private static let specialKeys: [UInt32: String] = [
        49: "Пробел", 36: "↩", 48: "⇥", 51: "⌫", 117: "⌦", 53: "⎋",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
    ]

    var isFunctionKey: Bool { DictationHotkey.functionKeys[keyCode] != nil }

    /// Подпись клавиши по ASCII-раскладке: при русской «V» не станет «М».
    static func keyName(_ code: UInt32) -> String {
        if let name = functionKeys[code] ?? specialKeys[code] { return name }

        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
            let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "#\(code)" }

        let layout = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = layout.withUnsafeBytes { bytes -> OSStatus in
            guard let base = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
                return OSStatus(paramErr)
            }
            return UCKeyTranslate(
                base, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(1 << kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "#\(code)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

final class DictationSettings: ObservableObject {
    static let shared = DictationSettings()

    static let defaultBroker = "http://192.168.222.189:8107"

    private enum Key {
        static let enabled = "dictation.enabled"
        static let trigger = "dictation.trigger"
        static let insert = "dictation.insert"
        static let paste = "dictation.paste"
        static let sounds = "dictation.sounds"
        static let broker = "dictation.broker"
        static let keyCode = "dictation.keyCode"
        static let modifiers = "dictation.modifiers"
    }

    private let defaults = UserDefaults.standard

    /// Вызывается после любой правки — контроллер перерегистрирует клавишу.
    var onChange: (() -> Void)?

    @Published var enabled: Bool { didSet { save(enabled, Key.enabled) } }
    @Published var trigger: DictationTrigger { didSet { save(trigger.rawValue, Key.trigger) } }
    @Published var insert: DictationInsert { didSet { save(insert.rawValue, Key.insert) } }
    @Published var pasteMethod: DictationPasteMethod { didSet { save(pasteMethod.rawValue, Key.paste) } }
    @Published var sounds: Bool { didSet { save(sounds, Key.sounds) } }
    @Published var brokerAddress: String { didSet { save(brokerAddress, Key.broker) } }
    @Published var hotkey: DictationHotkey {
        didSet {
            defaults.set(Int(hotkey.keyCode), forKey: Key.keyCode)
            save(Int(hotkey.modifiers), Key.modifiers)
        }
    }

    /// Не сохраняется: почему клавиша не зарегистрирована (занята и т.п.).
    @Published var hotkeyProblem: String?

    private var cachedToken: String?

    private init() {
        let defaults = UserDefaults.standard
        enabled = defaults.object(forKey: Key.enabled) as? Bool ?? true
        trigger = DictationTrigger(rawValue: defaults.string(forKey: Key.trigger) ?? "") ?? .hold
        insert = DictationInsert(rawValue: defaults.string(forKey: Key.insert) ?? "") ?? .live
        pasteMethod =
            DictationPasteMethod(rawValue: defaults.string(forKey: Key.paste) ?? "") ?? .clipboard
        sounds = defaults.object(forKey: Key.sounds) as? Bool ?? true
        brokerAddress = defaults.string(forKey: Key.broker) ?? DictationSettings.defaultBroker
        if let code = defaults.object(forKey: Key.keyCode) as? Int,
            let mods = defaults.object(forKey: Key.modifiers) as? Int
        {
            hotkey = DictationHotkey(keyCode: UInt32(code), modifiers: UInt32(mods))
        } else {
            hotkey = .standard
        }
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
        onChange?()
    }

    var token: String {
        get {
            if let cachedToken { return cachedToken }
            let value = DictationKeychain.read() ?? ""
            cachedToken = value
            return value
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed != cachedToken else { return }
            cachedToken = trimmed
            DictationKeychain.write(trimmed)
            objectWillChange.send()
            onChange?()
        }
    }

    /*
     * Одноразовый импорт токена: файл кладут по ssh (связка ключей в ssh-сессии
     * заперта), приложение в GUI-сессии переносит токен в Keychain и файл стирает.
     */
    static let importFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/SweepDongleAgent/dictation-token")

    func importTokenFileIfPresent() {
        let url = DictationSettings.importFile
        guard let data = try? Data(contentsOf: url) else { return }
        try? FileManager.default.removeItem(at: url)
        let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        token = value
        log("диктовка: токен перенесён из файла в Keychain, файл удалён")
    }

    /// Адрес без завершающей косой черты, или nil, если в поле мусор.
    var brokerURL: URL? {
        var text = brokerAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), let scheme = url.scheme,
            scheme == "http" || scheme == "https", url.host != nil
        else { return nil }
        return url
    }

    var isConfigured: Bool { brokerURL != nil && !token.isEmpty }
}

/// Токен брокера в связке ключей входа. Значение никогда не пишется в журнал.
enum DictationKeychain {
    private static let service = "ru.pazdnikoff.sweepdongle.dictation"
    private static let account = "broker-token"

    private static var base: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func read() -> String? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else {
            if status != errSecItemNotFound { log("диктовка: Keychain не отдал токен (\(status))") }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String) {
        if value.isEmpty {
            SecItemDelete(base as CFDictionary)
            return
        }
        let data = Data(value.utf8)
        var status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Sweep: токен брокера диктовки"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess { log("диктовка: Keychain не сохранил токен (\(status))") }
    }
}
