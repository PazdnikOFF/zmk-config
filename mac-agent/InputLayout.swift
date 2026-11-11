import AppKit
import Carbon

/*
 * Что напечатает клавиша в ТЕКУЩЕЙ раскладке macOS.
 *
 * Клавиатура шлёт коды физических клавиш US, а буква на экране зависит от
 * выбранного на маке языка: на русской раскладке Q — это Й, а Shift+3 (#
 * на SYM) — №. Поэтому подписи печатных клавиш в режиме Мак не берутся из
 * keymap.json как есть, а переводятся системой — UCKeyTranslate по данным
 * текущей раскладки. Сочетания (⌘C) остаются латиницей: так их пишет и сама
 * macOS, и работают они по латинской букве.
 *
 * Смена языка приходит распределённым уведомлением TIS — окно тут же
 * перерисовывается.
 */
final class InputLayout {
    static let shared = InputLayout()

    /// Двухбуквенный код языка раскладки: RU, EN.
    private(set) var language = "--"

    /// Зовётся на главной очереди после смены раскладки.
    var onChange: (() -> Void)?

    private var layoutData: Data?
    private var cache: [String: String] = [:]

    private init() {
        reload()

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.reload()
            self?.onChange?()
        }
    }

    /// Для проверки: раскладка по идентификатору источника ввода.
    init?(inputSourceID: String, language: String) {
        let filter = [kTISPropertyInputSourceID as String: inputSourceID] as CFDictionary
        guard
            let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue()
                as? [TISInputSource],
            let source = list.first,
            let data = Self.layoutData(of: source)
        else { return nil }

        layoutData = data
        self.language = language
    }

    private static func layoutData(of source: TISInputSource) -> Data? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        return Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
    }

    private func reload() {
        cache = [:]
        language = currentLayout()

        // Именно «раскладочный» источник: у методов ввода (китайский и т. п.)
        // своих данных раскладки нет, а этот вызов отдаёт ту, что под ними.
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else {
            layoutData = nil
            return
        }
        layoutData = Self.layoutData(of: source)
    }

    /// Подпись для клавиши-кода из keymap.json; nil — переводить нечего.
    func label(for code: KeyCode) -> String? {
        let cacheKey = code.key + (code.shift ? "+S" : "")
        if let hit = cache[cacheKey] { return hit }

        guard let virtualKey = Self.virtualKeys[code.key], let layoutData else { return nil }

        let text: String? = layoutData.withUnsafeBytes { raw in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return nil
            }

            var deadKeyState: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let modifiers: UInt32 = code.shift ? UInt32(shiftKey >> 8) & 0xFF : 0

            let status = UCKeyTranslate(
                layout, UInt16(virtualKey), UInt16(kUCKeyActionDisplay), modifiers,
                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                &deadKeyState, chars.count, &length, &chars)

            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }

        // Буквенные клавиши — заглавными, как на колпачках. Остальные — ровно
        // то, что напечатается: на SYM у [ и { разные «х» и «Х».
        let isLetterKey = code.key.count == 1 && !code.shift
        let result = text.map { isLetterKey ? $0.uppercased() : $0 }
        if let result { cache[cacheKey] = result }
        return result
    }

    /// Имена физических клавиш из keymap_gen.py -> виртуальные коды macOS.
    private static let virtualKeys: [String: Int] = [
        "A": kVK_ANSI_A, "B": kVK_ANSI_B, "C": kVK_ANSI_C, "D": kVK_ANSI_D, "E": kVK_ANSI_E,
        "F": kVK_ANSI_F, "G": kVK_ANSI_G, "H": kVK_ANSI_H, "I": kVK_ANSI_I, "J": kVK_ANSI_J,
        "K": kVK_ANSI_K, "L": kVK_ANSI_L, "M": kVK_ANSI_M, "N": kVK_ANSI_N, "O": kVK_ANSI_O,
        "P": kVK_ANSI_P, "Q": kVK_ANSI_Q, "R": kVK_ANSI_R, "S": kVK_ANSI_S, "T": kVK_ANSI_T,
        "U": kVK_ANSI_U, "V": kVK_ANSI_V, "W": kVK_ANSI_W, "X": kVK_ANSI_X, "Y": kVK_ANSI_Y,
        "Z": kVK_ANSI_Z,
        "N0": kVK_ANSI_0, "N1": kVK_ANSI_1, "N2": kVK_ANSI_2, "N3": kVK_ANSI_3, "N4": kVK_ANSI_4,
        "N5": kVK_ANSI_5, "N6": kVK_ANSI_6, "N7": kVK_ANSI_7, "N8": kVK_ANSI_8, "N9": kVK_ANSI_9,
        "MINUS": kVK_ANSI_Minus, "EQUAL": kVK_ANSI_Equal, "LBKT": kVK_ANSI_LeftBracket,
        "RBKT": kVK_ANSI_RightBracket, "BSLH": kVK_ANSI_Backslash, "SEMI": kVK_ANSI_Semicolon,
        "SQT": kVK_ANSI_Quote, "GRAVE": kVK_ANSI_Grave, "COMMA": kVK_ANSI_Comma,
        "DOT": kVK_ANSI_Period, "SLASH": kVK_ANSI_Slash,
    ]
}
