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
    }

    /// Имена слоёв держатся синхронно с config/cradio.keymap.
    static let layerNames = ["BASE", "SYM", "SYM2", "FN", "FN2"]

    var layerName: String {
        Int(layer) < Self.layerNames.count ? Self.layerNames[Int(layer)] : "L\(layer)"
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
