import AppKit

/*
 * Окно подсказок раскладки: схема 34 клавиш Sweep с текущим слоем.
 *
 * Плавающая HUD-панель (по HIG — для вспомогательной информации поверх
 * работы): не активирует приложение и не забирает фокус у того, где печатают,
 * висит на всех рабочих столах и над полноэкранными окнами. Двигается за фон,
 * положение запоминает AppKit (setFrameAutosaveName). Кнопка закрытия = снять
 * галочку «Подсказки» в меню.
 *
 * Что показывать, берётся из маски слоёв донгла: верхний рабочий слой и режим
 * ОС (флаг WIN/LNX). Вручную можно выбрать слой и режим — тогда маска
 * собирается так же, как её собрал бы ZMK, вместе с накладками ОС.
 */

final class HintsPanel: NSPanel {
    // Фокус клавиатуры окну не нужен: оно только показывает.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class LayerHintsController: NSObject, NSWindowDelegate {
    private static let visibleKey = "ru.pazdnikoff.sweepdongle.hintsVisible"
    private static let modeKey = "ru.pazdnikoff.sweepdongle.hintsMode"
    private static let layerKey = "ru.pazdnikoff.sweepdongle.hintsLayer"
    private static let autosaveName = "SweepLayerHints"

    /// Зовётся при показе и скрытии: агент подписывается на уведомления донгла
    /// о смене слоя, только пока окно на экране.
    var onVisibilityChange: ((Bool) -> Void)?

    private var panel: HintsPanel?
    private var needsPlacement = true

    /*
     * Shift и Caps Lock опрашиваются 20 раз в секунду, и только пока окно на
     * экране. CGEventSource.flagsState не требует разрешений (в отличие от
     * глобального перехвата событий) и стоит копейки.
     */
    private var modifierTimer: Timer?
    private var shiftHeld = false
    private var capsLock = false

    private func startModifierPolling() {
        guard modifierTimer == nil else { return }
        modifierTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.pollModifiers()
        }
        pollModifiers()
    }

    private func stopModifierPolling() {
        modifierTimer?.invalidate()
        modifierTimer = nil
    }

    private func pollModifiers() {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        let shift = flags.contains(.maskShift)
        let caps = flags.contains(.maskAlphaShift)
        guard shift != shiftHeld || caps != capsLock else { return }
        shiftHeld = shift
        capsLock = caps
        refresh()
    }
    private let keyboard = KeyboardView()
    private let legend = LayerLegendView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let modeControl = NSSegmentedControl()
    private let layerPopup = NSPopUpButton()

    private var state: DongleState?
    private var linkUp = false
    private var notificationsLive = false

    var isVisible: Bool { UserDefaults.standard.bool(forKey: Self.visibleKey) }

    /// nil — как на клавиатуре.
    private var manualMode: OSMode? {
        get { UserDefaults.standard.string(forKey: Self.modeKey).flatMap(OSMode.init(rawValue:)) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: Self.modeKey) }
    }

    /// nil — как на клавиатуре.
    private var manualLayer: Int? {
        get { UserDefaults.standard.object(forKey: Self.layerKey) as? Int }
        set { UserDefaults.standard.set(newValue, forKey: Self.layerKey) }
    }

    func restore() {
        if isVisible { show() }
    }

    func setVisible(_ visible: Bool) {
        UserDefaults.standard.set(visible, forKey: Self.visibleKey)
        if visible {
            show()
        } else {
            panel?.orderOut(nil)
            stopModifierPolling()
        }
        onVisibilityChange?(visible)
    }

    func update(state: DongleState?, linkUp: Bool, notificationsLive: Bool) {
        self.state = state
        self.linkUp = linkUp
        self.notificationsLive = notificationsLive
        refresh()
    }

    // MARK: - Окно

    private func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        refresh()
        place(panel)
        panel.orderFrontRegardless()
        startModifierPolling()
    }

    /*
     * Размер — по содержимому (setContentSize держит нижний левый угол, окно
     * растёт вверх). Первый раз и если сохранённое место ушло за экраны
     * (отключили монитор) — в правый нижний угол основного экрана.
     */
    private func place(_ panel: HintsPanel) {
        if let content = panel.contentView {
            panel.setContentSize(content.fittingSize)
        }

        let visible = NSScreen.screens.contains { $0.visibleFrame.contains(panel.frame) }
        guard needsPlacement || !visible,
            let screen = (NSScreen.screens.first ?? NSScreen.main)?.visibleFrame
        else { return }

        panel.setFrameOrigin(
            NSPoint(x: screen.maxX - panel.frame.width - 20, y: screen.minY + 20))
        needsPlacement = false
    }

    private func makePanel() -> HintsPanel {
        let panel = HintsPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 320),
            styleMask: [.titled, .closable, .utilityWindow, .hudWindow, .nonactivatingPanel],
            backing: .buffered, defer: false)

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false  // агент в фоне всегда «неактивен»
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.alphaValue = 0.92
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        InputLayout.shared.onChange = { [weak self] in self?.refresh() }
        panel.title = "Раскладка Sweep"

        modeControl.segmentCount = OSMode.allCases.count + 1
        modeControl.setLabel("Как на клавиатуре", forSegment: 0)
        for (i, mode) in OSMode.allCases.enumerated() {
            modeControl.setLabel(mode.title, forSegment: i + 1)
        }
        modeControl.controlSize = .small
        modeControl.trackingMode = .selectOne
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.setAccessibilityLabel("Режим ОС для подсказок")

        layerPopup.controlSize = .small
        layerPopup.target = self
        layerPopup.action = #selector(layerChanged)
        layerPopup.setAccessibilityLabel("Слой для подсказок")

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor

        let controls = NSStackView(views: [modeControl, layerPopup])
        controls.orientation = .horizontal
        controls.spacing = 8

        let stack = NSStackView(views: [keyboard, legend, statusLabel, controls])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        panel.contentView = content

        // Место, куда окно передвинули в прошлый раз; нет его — place()
        // поставит в угол экрана.
        panel.setContentSize(content.fittingSize)
        needsPlacement = !panel.setFrameUsingName(Self.autosaveName)
        panel.setFrameAutosaveName(Self.autosaveName)

        return panel
    }

    func windowWillClose(_ notification: Notification) {
        stopModifierPolling()
        UserDefaults.standard.set(false, forKey: Self.visibleKey)
        onVisibilityChange?(false)
    }

    @objc private func modeChanged() {
        let i = modeControl.selectedSegment
        manualMode = i <= 0 ? nil : OSMode.allCases[i - 1]
        refresh()
    }

    @objc private func layerChanged() {
        let tag = layerPopup.selectedTag()
        manualLayer = tag < 0 ? nil : tag
        refresh()
    }

    // MARK: - Содержимое

    private func refresh() {
        guard let panel, panel.isVisible || isVisible else { return }

        guard let keymap = Keymap.current else {
            keyboard.keys = []
            statusLabel.stringValue = "Нет keymap.json — пересоберите агент (make-keymap.sh)"
            return
        }

        rebuildLayerPopup(keymap)
        modeControl.selectedSegment = manualMode.map { OSMode.allCases.firstIndex(of: $0)! + 1 } ?? 0

        // Маска с клавиатуры. Старая прошивка (версия 2) маски не отдаёт —
        // тогда только верхний слой, без режима ОС.
        let liveMask: UInt32? =
            state.map { st in
                keymap.applyingConditional(
                    st.layerState ?? (Keymap.bit(0) | Keymap.bit(Int(st.layer))))
            }

        let liveMode = liveMask.map(keymap.mode(for:)) ?? .mac
        let liveLayer = liveMask.map(keymap.topWorkingLayer(in:)) ?? 0

        let mode = manualMode ?? liveMode
        let layer = manualLayer ?? liveLayer
        let mask =
            (manualMode == nil && manualLayer == nil && liveMask != nil)
            ? liveMask! : keymap.mask(layer: layer, mode: mode)

        let top = keymap.topWorkingLayer(in: mask)
        keyboard.layout = InputLayout.shared
        keyboard.shiftHeld = shiftHeld
        keyboard.capsLock = capsLock
        keyboard.keymap = keymap
        keyboard.topLayer = top
        keyboard.mode = mode
        keyboard.keys = keymap.resolve(mask: mask)

        legend.keymap = keymap
        legend.currentLayer = top
        legend.currentMode = mode
        legend.toolTip = keymap.hints.map { "• " + $0.text }.joined(separator: "\n")

        let manual = manualMode != nil || manualLayer != nil
        let language = mode == .mac ? " · \(InputLayout.shared.language)" : ""
        let caps = capsLock ? " · ⇪ Caps Lock" : ""
        panel.title =
            "\(keymap.layerName(layer)) · \(mode.title)\(language)\(caps)\(manual ? " (вручную)" : "")"

        statusLabel.stringValue = statusText(manual: manual)
    }

    private func statusText(manual: Bool) -> String {
        if !linkUp || state == nil {
            return "Донгл не на связи — показан выбранный вручную или базовый слой"
        }
        if state?.layerState == nil {
            return "Прошивка донгла без маски слоёв: режим ОС не виден, слой обновляется в паузах печати"
        }
        if !notificationsLive {
            return "Донгл не шлёт уведомления о слое — обновление в паузах печати"
        }
        return manual
            ? "Показан выбранный слой; клавиатура сейчас на другом"
            : "Жёлтым — при удержании · оранжевая точка — своя клавиша для ОС"
    }

    private func rebuildLayerPopup(_ keymap: Keymap) {
        let wanted = [-1] + keymap.workingLayers.map(\.index)
        let have = layerPopup.itemArray.map(\.tag)

        if wanted != have {
            layerPopup.removeAllItems()
            layerPopup.addItem(withTitle: "Слой как на клавиатуре")
            layerPopup.lastItem?.tag = -1
            for layer in keymap.workingLayers {
                layerPopup.addItem(withTitle: layer.name)
                layerPopup.lastItem?.tag = layer.index
            }
        }

        layerPopup.selectItem(withTag: manualLayer ?? -1)
    }
}

// MARK: - Схема клавиатуры

final class KeyboardView: NSView {
    var keys: [ResolvedKey] = [] { didSet { needsDisplay = true } }
    var mode: OSMode = .mac { didSet { needsDisplay = true } }
    var keymap: Keymap? { didSet { needsDisplay = true } }
    /// Раскладка macOS для печатных клавиш; используется только в режиме Мак.
    var layout: InputLayout? { didSet { needsDisplay = true } }
    /// Зажат ли Shift и включён ли Caps Lock на маке прямо сейчас.
    var shiftHeld = false { didSet { if shiftHeld != oldValue { needsDisplay = true } } }
    var capsLock = false { didSet { if capsLock != oldValue { needsDisplay = true } } }
    /// Верхний рабочий слой: от него зависит, какие комбо подписывать.
    var topLayer = 0 { didSet { needsDisplay = true } }

    private let keyW: CGFloat = 60
    private let keyH: CGFloat = 46
    private let gap: CGFloat = 5
    private let split: CGFloat = 36

    /*
     * Столбцовый сдвиг Sweep: мизинец ниже всех, средний выше всех.
     * Для левой руки слева направо, правая — зеркально.
     */
    private let stagger: [CGFloat] = [16, 6, 0, 5, 9]

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 10 * keyW + 8 * gap + split, height: 4 * (keyH + gap) + 42)
    }

    /// Прямоугольник клавиши по позиции ZMK (0–33).
    private func frame(for position: Int) -> NSRect {
        if position >= 30 {
            // Большие пальцы: 30–31 под левой, 32–33 под правой, ближе к центру.
            let column: Int
            switch position {
            case 30: column = 3
            case 31: column = 4
            case 32: column = 5
            default: column = 6
            }
            let left = x(forColumn: column) + (position < 32 ? keyW / 6 : -keyW / 6)
            let top = 3 * (keyH + gap) + 14 + (position == 30 || position == 33 ? 0 : 6)
            return NSRect(x: left, y: top, width: keyW, height: keyH)
        }

        let row = position / 10
        let column = position % 10
        let shift = column < 5 ? stagger[column] : stagger[9 - column]
        return NSRect(
            x: x(forColumn: column), y: CGFloat(row) * (keyH + gap) + shift, width: keyW,
            height: keyH)
    }

    private func x(forColumn column: Int) -> CGFloat {
        CGFloat(column) * (keyW + gap) + (column >= 5 ? split - gap : 0)
    }

    override func draw(_ dirtyRect: NSRect) {
        for (position, key) in keys.enumerated() where position < 34 {
            drawKey(key, in: frame(for: position))
        }
        drawCombos()
    }

    /*
     * Комбо слоёв прямо на схеме: плашка цветом слоя под большими пальцами,
     * которые жмут вместе. Комбо режима ОС на схеме не рисуются — владелец
     * счёл их лишними посреди клавиатуры; они есть в строке слоёв внизу.
     */
    private func drawCombos() {
        guard let keymap else { return }

        for access in keymap.access ?? [] where access.combo && (access.on == 0 || access.on == topLayer) {
            let frames = access.positions.map(frame(for:))
            guard let first = frames.first else { continue }
            let union = frames.dropFirst().reduce(first) { $0.union($1) }
            let color = LayerPalette.color(access.layer, in: keymap)
            let glyph = access.how == "toggle" ? "⇄ " : ""
            drawCapsule(
                glyph + keymap.layerName(access.layer),
                center: NSPoint(x: union.midX, y: union.maxY + 9), fill: color)
        }
    }

    private func drawCapsule(_ text: String, center: NSPoint, fill: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9.5, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let rect = NSRect(
            x: center.x - size.width / 2 - 6, y: center.y - 7.5, width: size.width + 12, height: 15)
        fill.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7.5, yRadius: 7.5).fill()
        (text as NSString).draw(
            at: NSPoint(x: rect.minX + 6, y: rect.midY - size.height / 2), withAttributes: attrs)
    }

    private func drawKey(_ key: ResolvedKey, in rect: NSRect) {
        let binding = key.binding
        let danger = binding.danger?[mode] ?? false
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)

        let fill: NSColor
        if binding.isNone {
            fill = NSColor.white.withAlphaComponent(0.03)
        } else if danger {
            fill = NSColor.systemRed.withAlphaComponent(0.38)
        } else if binding.kind == "layer", let keymap, let layer = binding.layer {
            fill = LayerPalette.color(layer, in: keymap).withAlphaComponent(0.55)
        } else if isActiveModifier(binding) {
            // Shift зажат прямо сейчас — подсвечиваем саму клавишу.
            fill = NSColor.systemYellow.withAlphaComponent(0.55)
        } else if key.fromBelow {
            fill = NSColor.white.withAlphaComponent(0.05)
        } else {
            fill = NSColor.white.withAlphaComponent(0.13)
        }
        fill.setFill()
        path.fill()

        if danger {
            NSColor.systemRed.setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }

        // Клавишу подменила накладка ОС — точка в углу.
        if key.fromOverlay {
            NSColor.systemOrange.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.minX + 5, y: rect.minY + 5, width: 5, height: 5))
                .fill()
        }

        guard !binding.isNone, let label = text(binding.code, fallback: binding.label?[mode]) else {
            return
        }

        let primary: NSColor = key.fromBelow ? .tertiaryLabelColor : .labelColor
        let secondary: NSColor = key.fromBelow ? .quaternaryLabelColor : .secondaryLabelColor
        let note = binding.note?[mode] ?? nil
        let inner = rect.insetBy(dx: 4, dy: 3)

        // Действие при удержании — жёлтым вверху справа, заметно, но не
        // крупнее основного.
        var top: CGFloat = 8
        if let hold = text(binding.holdCode, fallback: binding.hold?[mode]) {
            let color = key.fromBelow ? NSColor.systemYellow.withAlphaComponent(0.45) : .systemYellow
            drawBold(
                hold, in: NSRect(x: inner.minX, y: inner.minY - 1, width: inner.width, height: 14),
                size: 11.5, color: color)
            top = 12
        }

        let noteHeight: CGFloat = note == nil ? 0 : 11
        let labelRect = NSRect(
            x: inner.minX, y: inner.minY + top, width: inner.width,
            height: inner.height - top - noteHeight)
        drawFitting(label, in: labelRect, color: primary)

        if let note {
            draw(
                note,
                in: NSRect(x: inner.minX, y: inner.maxY - 11, width: inner.width, height: 11),
                size: 8.5, color: secondary, alignment: .center)
        }
    }

    private func isActiveModifier(_ binding: KeyBinding) -> Bool {
        shiftHeld && binding.kind == "mod" && (binding.label?.mac.hasSuffix("Shift") ?? false)
    }

    /// В режиме Мак печатная клавиша подписывается тем, что она напечатает в
    /// выбранной на маке раскладке (Й вместо Q); иначе — подпись из keymap.
    private func text(_ code: KeyCode?, fallback: String?) -> String? {
        guard mode == .mac, let code, let layout,
            let typed = layout.label(for: code, shift: shiftHeld, capsLock: capsLock)
        else {
            return fallback
        }
        return typed
    }

    private func attributes(size: CGFloat, weight: NSFont.Weight, color: NSColor, alignment: NSTextAlignment)
        -> [NSAttributedString.Key: Any]
    {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = .byWordWrapping
        return [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: style,
        ]
    }

    /// Основная подпись: крупно, а длинную ужимаем и переносим по словам.
    private func drawFitting(_ text: String, in rect: NSRect, color: NSColor) {
        var size: CGFloat = 14
        var attrs = attributes(size: size, weight: .semibold, color: color, alignment: .center)
        var bounds = (text as NSString).boundingRect(
            with: NSSize(width: rect.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin], attributes: attrs)

        while size > 7.5, bounds.height > rect.height || bounds.width > rect.width + 0.5
            || longestWordWidth(text, attrs) > rect.width
        {
            size -= 0.5
            attrs = attributes(size: size, weight: .semibold, color: color, alignment: .center)
            bounds = (text as NSString).boundingRect(
                with: NSSize(width: rect.width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin], attributes: attrs)
        }

        let y = rect.minY + max(0, (rect.height - bounds.height) / 2)
        (text as NSString).draw(
            with: NSRect(x: rect.minX, y: y, width: rect.width, height: bounds.height),
            options: [.usesLineFragmentOrigin], attributes: attrs)
    }

    private func longestWordWidth(_ text: String, _ attrs: [NSAttributedString.Key: Any]) -> CGFloat {
        text.split(separator: " ").map { (String($0) as NSString).size(withAttributes: attrs).width }
            .max() ?? 0
    }

    private func drawBold(_ text: String, in rect: NSRect, size: CGFloat, color: NSColor) {
        let attrs = attributes(size: size, weight: .bold, color: color, alignment: .right)
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin], attributes: attrs)
    }

    private func draw(
        _ text: String, in rect: NSRect, size: CGFloat, color: NSColor, alignment: NSTextAlignment
    ) {
        var attrs = attributes(size: size, weight: .regular, color: color, alignment: alignment)
        let style = (attrs[.paragraphStyle] as! NSParagraphStyle).mutableCopy() as! NSMutableParagraphStyle
        style.lineBreakMode = .byTruncatingTail
        attrs[.paragraphStyle] = style
        (text as NSString).draw(
            with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: attrs)
    }
}

// MARK: - Цвета слоёв

/// Свой цвет у каждого рабочего слоя: в строке-легенде, на клавишах перехода
/// и на плашках комбо. Системные цвета — подстраиваются под тему и контраст.
enum LayerPalette {
    private static let colors: [NSColor] = [
        .systemBlue, .systemPurple, .systemGreen, .systemTeal, .systemPink, .systemIndigo,
        .systemBrown,
    ]

    static func color(_ layer: Int, in keymap: Keymap) -> NSColor {
        let order = keymap.workingLayers.map(\.index).filter { $0 != 0 }
        guard let i = order.firstIndex(of: layer) else { return .systemGray }
        return colors[i % colors.count]
    }
}

// MARK: - Строка «как попасть на слой»

/*
 * Одна строка цветных плашек: на каждой — значок четырёх больших пальцев с
 * подсвеченными нужными, значок «удерживать» или «вкл/выкл» и имя слоя.
 * Плашка текущего слоя залита. В конце — выбор режима ОС парами клавиш.
 */
final class LayerLegendView: NSView {
    var keymap: Keymap? { didSet { needsDisplay = true } }
    var currentLayer = 0 { didSet { needsDisplay = true } }
    var currentMode: OSMode = .mac { didSet { needsDisplay = true } }

    private let height: CGFloat = 24
    private let spacing: CGFloat = 6

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize { NSSize(width: 676, height: height) }

    private struct Chip {
        let positions: [Int]
        let symbol: String?
        let text: String
        let color: NSColor
        let filled: Bool
    }

    private func chips(_ keymap: Keymap) -> [Chip] {
        let order = keymap.workingLayers.map(\.index)
        let access = (keymap.access ?? []).sorted {
            (order.firstIndex(of: $0.layer) ?? 99) < (order.firstIndex(of: $1.layer) ?? 99)
        }

        var result = access.map { a in
            Chip(
                positions: a.positions,
                symbol: a.how == "hold" ? "hand.point.down.fill" : "togglepower",
                text: keymap.layerName(a.layer),
                color: LayerPalette.color(a.layer, in: keymap),
                filled: a.layer == currentLayer)
        }

        if let modes = keymap.modes, !modes.isEmpty {
            let pairs = modes.map { m in
                "\(m.keys.joined(separator: "+")) \(m.osMode?.title ?? m.mode)"
            }
            let on = modes[0].on
            result.append(
                Chip(
                    positions: [], symbol: "desktopcomputer",
                    text: pairs.joined(separator: " · ") + (on != 0 ? " (на \(keymap.layerName(on)))" : ""),
                    color: on != 0 ? LayerPalette.color(on, in: keymap) : .systemGray,
                    filled: currentLayer == on))
        }

        return result
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let keymap else { return }

        var fontSize: CGFloat = 11.5
        var list = chips(keymap)
        // Не влезает в строку — ужимаем шрифт, а не переносим.
        while fontSize > 8.5, totalWidth(list, fontSize) > bounds.width {
            fontSize -= 0.5
            list = chips(keymap)
        }

        var x: CGFloat = 0
        for chip in list {
            x += drawChip(chip, at: x, fontSize: fontSize) + spacing
        }
    }

    private func textAttrs(_ chip: Chip, _ size: CGFloat) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold),
            // Цвет слоя — у фона и значков; текст обычный, чтобы читался.
            .foregroundColor: chip.filled ? NSColor.white : NSColor.labelColor,
        ]
    }

    private func iconWidth(_ chip: Chip) -> CGFloat {
        chip.positions.allSatisfy { $0 >= 30 } && !chip.positions.isEmpty ? 34 : 0
    }

    private func chipWidth(_ chip: Chip, _ size: CGFloat) -> CGFloat {
        let text = (chip.text as NSString).size(withAttributes: textAttrs(chip, size)).width
        let keys = iconWidth(chip) == 0 && !chip.positions.isEmpty ? 0 : iconWidth(chip)
        return 8 + keys + (keys > 0 ? 5 : 0) + (chip.symbol != nil ? size + 4 : 0) + text + 8
    }

    private func totalWidth(_ list: [Chip], _ size: CGFloat) -> CGFloat {
        list.map { chipWidth($0, size) }.reduce(0, +) + spacing * CGFloat(max(0, list.count - 1))
    }

    @discardableResult
    private func drawChip(_ chip: Chip, at x: CGFloat, fontSize: CGFloat) -> CGFloat {
        let width = chipWidth(chip, fontSize)
        let rect = NSRect(x: x, y: 2, width: width, height: height - 4)
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        chip.color.withAlphaComponent(chip.filled ? 0.85 : 0.22).setFill()
        path.fill()
        if !chip.filled {
            chip.color.withAlphaComponent(0.7).setStroke()
            path.lineWidth = 1
            path.stroke()
        }

        var cursor = rect.minX + 8

        if iconWidth(chip) > 0 {
            drawThumbs(chip, in: NSRect(x: cursor, y: rect.minY + 4, width: 34, height: rect.height - 8))
            cursor += 34 + 5
        }

        let tint: NSColor = chip.filled ? .white : chip.color
        if let name = chip.symbol,
            let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(
                    NSImage.SymbolConfiguration(pointSize: fontSize - 1, weight: .semibold)
                        .applying(NSImage.SymbolConfiguration(paletteColors: [tint])))
        {
            let side = fontSize
            image.draw(
                in: NSRect(x: cursor, y: rect.midY - side / 2, width: side, height: side),
                from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            cursor += side + 4
        }

        let attrs = textAttrs(chip, fontSize)
        let size = (chip.text as NSString).size(withAttributes: attrs)
        (chip.text as NSString).draw(
            at: NSPoint(x: cursor, y: rect.midY - size.height / 2), withAttributes: attrs)

        return width
    }

    /// Четыре больших пальца: два слева, два справа; нужные — залиты.
    private func drawThumbs(_ chip: Chip, in rect: NSRect) {
        let w: CGFloat = 6.5
        let xs: [Int: CGFloat] = [30: 0, 31: w + 2, 32: 2 * w + 7, 33: 3 * w + 9]
        let on: NSColor = chip.filled ? .white : chip.color
        for (position, dx) in xs {
            let key = NSRect(x: rect.minX + dx, y: rect.minY, width: w, height: rect.height)
            let path = NSBezierPath(roundedRect: key, xRadius: 1.5, yRadius: 1.5)
            if chip.positions.contains(position) {
                on.setFill()
                path.fill()
            } else {
                on.withAlphaComponent(0.45).setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        }
    }
}
