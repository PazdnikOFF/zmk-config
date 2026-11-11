import Carbon

/*
 * Глобальные клавиши через Carbon RegisterEventHotKey.
 *
 * Почему не CGEventTap: хоткей Carbon не требует разрешения «Мониторинг ввода»,
 * работает при включённом Secure Input (event tap там глохнет — Handy ради этого
 * дублирует свои клавиши Carbon-хоткеями) и сам глотает нажатие, так что ⌥Пробел
 * не напечатает неразрывный пробел. Отпускание приходит отдельным событием —
 * этого достаточно для режима удержания.
 *
 * Ограничение: сочетание должно содержать обычную клавишу; одиночный модификатор
 * (правый ⌥ и т.п.) так не поймать.
 */
final class DictationHotkeys {
    static let shared = DictationHotkeys()

    struct Handlers {
        var pressed: () -> Void
        var released: () -> Void
    }

    private var installed = false
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: Handlers] = [:]

    private static let signature: OSType = 0x5357_4450  // 'SWDP'

    private func installIfNeeded() {
        guard !installed else { return }
        installed = true

        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                guard let event else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard status == noErr else { return status }
                let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
                DictationHotkeys.shared.dispatch(id: id.id, pressed: pressed)
                return noErr
            }, types.count, &types, nil, nil)
        if status != noErr { log("диктовка: обработчик клавиш не установлен (\(status))") }
    }

    private func dispatch(id: UInt32, pressed: Bool) {
        guard let handler = handlers[id] else { return }
        pressed ? handler.pressed() : handler.released()
    }

    /// false — сочетание уже занято другой программой или системой.
    @discardableResult
    func register(id: UInt32, hotkey: DictationHotkey, handlers: Handlers) -> Bool {
        installIfNeeded()
        unregister(id: id)

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            hotkey.keyCode, hotkey.modifiers,
            EventHotKeyID(signature: DictationHotkeys.signature, id: id),
            GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            log("диктовка: сочетание \(hotkey.title) не зарегистрировано (\(status))")
            return false
        }
        refs[id] = ref
        self.handlers[id] = handlers
        return true
    }

    func unregister(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        handlers.removeValue(forKey: id)
    }

    func isRegistered(id: UInt32) -> Bool { refs[id] != nil }
}
