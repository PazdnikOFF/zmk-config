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
    private let keyboard = KeyboardView()
    private let hintsLabel = NSTextField(wrappingLabelWithString: "")
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
        if visible { show() } else { panel?.orderOut(nil) }
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
        panel.orderFrontRegardless()
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

        for label in [hintsLabel, statusLabel] {
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
        }
        hintsLabel.preferredMaxLayoutWidth = keyboard.intrinsicContentSize.width

        let controls = NSStackView(views: [modeControl, layerPopup])
        controls.orientation = .horizontal
        controls.spacing = 8

        let stack = NSStackView(views: [keyboard, hintsLabel, statusLabel, controls])
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

        // Первое появление — справа внизу; дальше AppKit сам ставит туда,
        // куда окно передвинули в прошлый раз.
        panel.setContentSize(content.fittingSize)
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(
                NSPoint(x: screen.maxX - panel.frame.width - 20, y: screen.minY + 20))
        }
        panel.setFrameAutosaveName(Self.autosaveName)

        return panel
    }

    func windowWillClose(_ notification: Notification) {
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

        keyboard.mode = mode
        keyboard.keys = keymap.resolve(mask: mask)

        let manual = manualMode != nil || manualLayer != nil
        panel.title = "\(keymap.layerName(layer)) · \(mode.title)\(manual ? " (вручную)" : "")"

        hintsLabel.stringValue = keymap.hints.map { "• " + $0.text }.joined(separator: "\n")
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
        return manual ? "Показан выбранный слой; клавиатура сейчас на другом" : ""
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
        NSSize(width: 10 * keyW + 8 * gap + split, height: 4 * (keyH + gap) + 30)
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
            let left = x(forColumn: column) + (position < 32 ? keyW / 3 : -keyW / 3)
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
        } else if binding.kind == "layer" {
            fill = NSColor.controlAccentColor.withAlphaComponent(0.35)
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

        guard !binding.isNone, let label = binding.label?[mode] else { return }

        let primary: NSColor = key.fromBelow ? .tertiaryLabelColor : .labelColor
        let secondary: NSColor = key.fromBelow ? .quaternaryLabelColor : .secondaryLabelColor
        let note = binding.note?[mode] ?? nil
        let inner = rect.insetBy(dx: 4, dy: 3)

        if let hold = binding.hold?[mode] {
            draw(
                hold, in: NSRect(x: inner.minX, y: inner.minY, width: inner.width, height: 11),
                size: 9, color: secondary, alignment: .right)
        }

        let noteHeight: CGFloat = note == nil ? 0 : 11
        let labelRect = NSRect(
            x: inner.minX, y: inner.minY + 8, width: inner.width,
            height: inner.height - 8 - noteHeight)
        drawFitting(label, in: labelRect, color: primary)

        if let note {
            draw(
                note,
                in: NSRect(x: inner.minX, y: inner.maxY - 11, width: inner.width, height: 11),
                size: 8.5, color: secondary, alignment: .center)
        }
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
