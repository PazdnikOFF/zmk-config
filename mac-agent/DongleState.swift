import Foundation

/*
 * Разбор характеристики состояния донгла.
 *
 * Раскладка задана в dongle/src/dongle_ui.h и разбирается побайтно, поэтому
 * первым идёт номер версии: поля добавляются только в конец и с её ростом.
 * Незнакомую старшую версию читаем в тех полях, которые знаем, — остальное
 * просто игнорируем.
 */
struct DongleState {
    static let batteryUnknown: UInt8 = 0xFF

    var layer: UInt8
    var battLeft: UInt8
    var battRight: UInt8
    var battDongle: UInt8
    var btProfile: UInt8  // нумерация с единицы; 0 означает USB
    var btFlags: UInt8

    /// Какой слот периферии донгл считает левой половиной; nil — ещё не знает.
    /// Показывается в меню, чтобы расхождение с панелью можно было увидеть.
    var leftSlot: UInt8?

    /// Маска активных слоёв (бит N — слой N в порядке cradio.keymap), с
    /// третьей версии прошивки; nil — донгл её не отдаёт.
    var layerState: UInt32?

    var isUSB: Bool { btFlags & 0b100 != 0 }
    var isConnected: Bool { btFlags & 0b001 != 0 }
    var isOpen: Bool { btFlags & 0b010 != 0 }

    init?(_ data: Data) {
        guard data.count >= 7, data[0] >= 1 else { return nil }

        layer = data[1]
        battLeft = data[2]
        battRight = data[3]
        battDongle = data[4]
        btProfile = data[5]
        btFlags = data[6]

        // Поле появилось во второй версии — у первой его просто нет.
        leftSlot = (data.count >= 8 && data[7] != 0xFF) ? data[7] : nil

        // Третья версия: маска слоёв, little-endian.
        if data[0] >= 3, data.count >= 12 {
            layerState = (0..<4).reduce(UInt32(0)) { acc, i in
                acc | UInt32(data[8 + i]) << (8 * UInt32(i))
            }
        }
    }

    /// Имя берётся из keymap.json, который сгенерирован из cradio.keymap.
    var layerName: String {
        guard let keymap = Keymap.current else { return "L\(layer)" }

        guard let mask = layerState else { return keymap.layerName(Int(layer)) }

        let full = keymap.applyingConditional(mask)
        return keymap.layerName(keymap.topWorkingLayer(in: full))
    }

    /// Режим ОС по флаг-слою; nil — прошивка маску не отдаёт.
    var osMode: OSMode? {
        guard let mask = layerState, let keymap = Keymap.current else { return nil }
        return keymap.mode(for: mask)
    }

    var outputDescription: String {
        if isUSB { return "USB" }
        if isOpen { return "BT\(btProfile) — ждёт сопряжения" }
        return isConnected ? "BT\(btProfile) — подключён" : "BT\(btProfile) — нет связи"
    }

    /// Наименьший из известных зарядов — он и выносится в строку состояния.
    var lowestBattery: UInt8? {
        [battLeft, battRight, battDongle]
            .filter { $0 != Self.batteryUnknown }
            .min()
    }

    static func percentText(_ value: UInt8) -> String {
        value == batteryUnknown ? "—" : "\(value)%"
    }
}
