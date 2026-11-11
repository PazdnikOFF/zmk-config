import Foundation

/*
 * Раскладка клавиатуры для окна подсказок.
 *
 * Данные не пишутся руками: их генерирует keymap_gen.py из
 * config/cradio.keymap (см. make-keymap.sh). Файл keymap.json лежит в бандле;
 * если есть свежий в ~/Library/Application Support/SweepDongleAgent/, берётся
 * он — так поправленную раскладку можно привезти на мак без пересборки агента.
 */

enum OSMode: String, CaseIterable {
    case mac, win, lnx

    var title: String {
        switch self {
        case .mac: return "Мак"
        case .win: return "Windows"
        case .lnx: return "Linux"
        }
    }
}

/// Значение, подготовленное генератором отдельно для каждого режима ОС.
struct PerMode<Value: Decodable>: Decodable {
    let mac: Value
    let win: Value
    let lnx: Value

    subscript(mode: OSMode) -> Value {
        switch mode {
        case .mac: return mac
        case .win: return win
        case .lnx: return lnx
        }
    }
}

/// Физическая клавиша US и Shift — для перевода в текущую раскладку macOS.
struct KeyCode: Decodable {
    let key: String
    let shift: Bool
}

struct KeyBinding: Decodable {
    /// "key", "trans" (прозрачная — берётся с нижнего слоя) или "none".
    let t: String
    /// key, mod, media, action, macro, layer, bt, out, danger, other.
    let kind: String?
    let label: PerMode<String>?
    let note: PerMode<String?>?
    let hold: PerMode<String>?
    let danger: PerMode<Bool>?
    let layer: Int?
    /// Есть у печатных клавиш: что нажимается физически.
    let code: KeyCode?
    let holdCode: KeyCode?

    var isTransparent: Bool { t == "trans" }
    var isNone: Bool { t == "none" }
}

struct KeymapLayer: Decodable {
    let index: Int
    let node: String
    let name: String
    let keys: [KeyBinding]
}

struct ConditionalLayer: Decodable {
    let conditions: [Int]
    let then: Int

    enum CodingKeys: String, CodingKey {
        case conditions = "if"
        case then
    }
}

struct KeymapCombo: Decodable {
    let node: String
    let positions: [Int]
    let binding: KeyBinding
    let layers: [Int]
}

struct KeymapHint: Decodable {
    /// Слой, о котором подсказка; -1 — режим ОС.
    let layer: Int
    let text: String
}

/// Как попасть на слой: удержать / нажать вместе (комбо) и где это работает.
struct LayerAccess: Decodable {
    let layer: Int
    /// hold, toggle, to, once.
    let how: String
    let positions: [Int]
    /// На каком слое работает; 0 — с базы (и со всех, если это комбо).
    let on: Int
    let combo: Bool
}

/// Комбо выбора режима ОС: «R+T — Мак» на слое SYM_2.
struct ModeSwitch: Decodable {
    let mode: String
    let positions: [Int]
    let keys: [String]
    let on: Int

    var osMode: OSMode? { OSMode(rawValue: mode) }
}

struct KeymapFlags: Decodable {
    let win: Int
    let lnx: Int
}

/// Клавиша, какой она получилась на текущем наборе слоёв.
struct ResolvedKey {
    let binding: KeyBinding
    /// С какого слоя взята привязка.
    let sourceLayer: Int
    /// Привязка провалилась сквозь &trans на нижний слой.
    let fromBelow: Bool
    /// Привязку дала накладка ОС (*_W / *_L).
    let fromOverlay: Bool
}

struct Keymap: Decodable {
    let keyCount: Int
    let flags: KeymapFlags
    let layers: [KeymapLayer]
    let conditional: [ConditionalLayer]
    let combos: [KeymapCombo]
    let hints: [KeymapHint]
    /// Появились позже hints — в старом keymap.json их может не быть.
    let access: [LayerAccess]?
    let modes: [ModeSwitch]?

    // MARK: - Загрузка

    static let overrideURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/SweepDongleAgent/keymap.json")

    private static var cached: (keymap: Keymap, url: URL, modified: Date?)?

    private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /*
     * Текущая раскладка. Из двух файлов — в бандле и привезённого
     * make-keymap.sh --push — берётся более свежий: иначе старый привезённый
     * заслонил бы новый бандл после пересборки. Перечитывается, только если
     * файл сменился.
     */
    static var current: Keymap? {
        let candidates = [overrideURL, Bundle.main.url(forResource: "keymap", withExtension: "json")]
            .compactMap { $0 }
            .compactMap { url in modificationDate(url).map { (url, $0) } }

        guard let newest = candidates.max(by: { $0.1 < $1.1 }) else { return nil }
        let (url, modified) = newest

        if let cached, cached.url == url, cached.modified == modified {
            return cached.keymap
        }

        do {
            let keymap = try JSONDecoder().decode(Keymap.self, from: Data(contentsOf: url))
            cached = (keymap, url, modified)
            log("раскладка: \(url.path), слоёв \(keymap.layers.count)")
            return keymap
        } catch {
            log("раскладка: не разобрать \(url.path): \(error)")
            return cached?.keymap
        }
    }

    // MARK: - Слои

    var flagLayers: Set<Int> { [flags.win, flags.lnx] }
    var overlayLayers: Set<Int> { Set(conditional.map(\.then)) }

    /// Слои, на которые переходят клавишами: без флагов ОС и без накладок.
    var workingLayers: [KeymapLayer] {
        layers.filter { !flagLayers.contains($0.index) && !overlayLayers.contains($0.index) }
    }

    func layerName(_ index: Int) -> String {
        layers.first(where: { $0.index == index })?.name ?? "L\(index)"
    }

    static func bit(_ index: Int) -> UInt32 {
        (0..<32).contains(index) ? UInt32(1) << UInt32(index) : 0
    }

    /// Как conditional_layers в ZMK: накладка поднята, когда подняты все её условия.
    func applyingConditional(_ mask: UInt32) -> UInt32 {
        var result = mask & ~conditional.reduce(0) { $0 | Self.bit($1.then) }

        for rule in conditional {
            let need = rule.conditions.reduce(UInt32(0)) { $0 | Self.bit($1) }
            if result & need == need {
                result |= Self.bit(rule.then)
            }
        }

        return result
    }

    func mode(for mask: UInt32) -> OSMode {
        if mask & Self.bit(flags.win) != 0 { return .win }
        if mask & Self.bit(flags.lnx) != 0 { return .lnx }
        return .mac
    }

    /// Маска, которую дала бы клавиатура на этом слое в этом режиме.
    func mask(layer: Int, mode: OSMode) -> UInt32 {
        var mask = Self.bit(0) | Self.bit(layer)

        switch mode {
        case .mac: break
        case .win: mask |= Self.bit(flags.win)
        case .lnx: mask |= Self.bit(flags.lnx)
        }

        return applyingConditional(mask)
    }

    /// Верхний рабочий слой — его имя и показывается в заголовке.
    func topWorkingLayer(in mask: UInt32) -> Int {
        let working = Set(workingLayers.map(\.index))

        for layer in layers.reversed() where layer.index != 0 && working.contains(layer.index) {
            if mask & Self.bit(layer.index) != 0 {
                return layer.index
            }
        }

        return 0
    }

    /// Что окажется на каждой позиции: как в ZMK, сверху вниз до первой не-&trans.
    func resolve(mask: UInt32) -> [ResolvedKey] {
        let overlays = overlayLayers

        return (0..<keyCount).map { position in
            var skipped = false

            for layer in layers.reversed() {
                guard layer.index == 0 || mask & Self.bit(layer.index) != 0,
                    position < layer.keys.count
                else { continue }

                let binding = layer.keys[position]

                if binding.isTransparent {
                    skipped = true
                    continue
                }

                // Флаг ОС пустой, его &trans просто пропускаем, а не считаем
                // «провалом» на нижний слой: на базе это и есть сама база.
                let fromBelow = skipped && !overlays.contains(layer.index)

                return ResolvedKey(
                    binding: binding, sourceLayer: layer.index,
                    fromBelow: fromBelow && layer.index != topWorkingLayer(in: mask),
                    fromOverlay: overlays.contains(layer.index))
            }

            return ResolvedKey(
                binding: KeyBinding(
                    t: "none", kind: nil, label: nil, note: nil, hold: nil, danger: nil,
                    layer: nil, code: nil, holdCode: nil),
                sourceLayer: 0, fromBelow: false, fromOverlay: false)
        }
    }
}
