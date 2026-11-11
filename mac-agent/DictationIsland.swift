import AppKit
import QuartzCore

/*
 * «Островок» диктовки: маленькая HUD-панель внизу экрана над Dock.
 *
 * Повторяет оверлей Handy: монитор — тот, где курсор; по центру, на 15 pt выше
 * рабочей области (то есть над Dock); точка записи серая, пока колонка не
 * начала слушать, и красная после; 9 полосок уровня; кнопка отмены справа;
 * «Распознаю…» со спиннером после отпускания; уведомление держится 4 с.
 *
 * Панель неактивирующая и фокус не берёт никогда: иначе ⌘V ушла бы в неё, а не
 * в поле, куда диктуют.
 */
final class DictationIsland: NSObject {
    enum Phase { case hidden, recording, transcribing, notice }

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private final class FirstMouseButton: NSButton {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    /// Клик по уведомлению закрывает его, как у Handy.
    private final class ClickView: NSView {
        var onClick: (() -> Void)?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { onClick?() }
    }

    private static let compactWidth: CGFloat = 212
    private static let rowHeight: CGFloat = 40
    private static let textWidth: CGFloat = 392
    private static let bottomGap: CGFloat = 15
    private static let noticeHold: TimeInterval = 4

    var onCancel: (() -> Void)?
    private(set) var phase: Phase = .hidden

    private let panel: Panel
    private let background = NSVisualEffectView()
    private let content = ClickView()
    private let dot = CALayer()
    private let spinner = NSProgressIndicator()
    private let symbol = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let transcript = NSTextField(wrappingLabelWithString: "")
    private let bars = DictationLevelBars()
    private let cancelButton = FirstMouseButton()

    private var generation = 0
    private var noticeTimer: Timer?

    override init() {
        panel = Panel(
            contentRect: NSRect(x: 0, y: 0, width: DictationIsland.compactWidth, height: DictationIsland.rowHeight),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .vibrantDark)
        panel.setAccessibilityRole(.group)

        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = DictationIsland.rowHeight / 2
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 1
        background.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        background.autoresizingMask = [.width, .height]
        panel.contentView = background

        content.frame = background.bounds
        content.autoresizingMask = [.width, .height]
        content.wantsLayer = true
        background.addSubview(content)

        dot.bounds = CGRect(x: 0, y: 0, width: 8, height: 8)
        dot.cornerRadius = 4
        content.layer?.addSublayer(dot)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        content.addSubview(spinner)

        symbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        content.addSubview(symbol)

        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        content.addSubview(label)

        transcript.font = .systemFont(ofSize: 13)
        transcript.textColor = .secondaryLabelColor
        transcript.maximumNumberOfLines = 2
        transcript.lineBreakMode = .byTruncatingHead
        content.addSubview(transcript)

        content.addSubview(bars)

        cancelButton.bezelStyle = .regularSquare
        cancelButton.isBordered = false
        cancelButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Отменить")
        cancelButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
        cancelButton.contentTintColor = .secondaryLabelColor
        cancelButton.imagePosition = .imageOnly
        cancelButton.toolTip = "Отменить (Esc)"
        cancelButton.setAccessibilityLabel("Отменить диктовку")
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        content.addSubview(cancelButton)

        content.onClick = { [weak self] in
            if self?.phase == .notice { self?.hide() }
        }
    }

    @objc private func cancelClicked() { onCancel?() }

    // MARK: - Состояния

    /// Нажали клавишу. armed=false — колонка ещё не слушает: точка серая.
    func showRecording() {
        phase = .recording
        noticeTimer?.invalidate()
        transcript.stringValue = ""
        // Пока колонка не слушает — явно «подключаюсь», без полосок: иначе
        // непонятно, пошла ли запись (так и было в первой версии).
        label.stringValue = "Подключаюсь…"
        label.textColor = .secondaryLabelColor
        setArmed(false)
        bars.reset()
        spinner.stopAnimation(nil)
        symbol.isHidden = true
        dot.isHidden = false
        bars.isHidden = true
        cancelButton.isHidden = false
        layout()
        present()
        content.setAccessibilityLabel("Диктовка: подключаюсь")
    }

    /// Колонка слушает: «Говорите», точка красная и пульсирует, полоски живые.
    func setListening() {
        guard phase == .recording else { return }
        label.stringValue = "Говорите"
        label.textColor = .labelColor
        setArmed(true)
        bars.armed = true
        bars.isHidden = false
        layout()
        content.setAccessibilityLabel("Диктовка: запись, говорите")
        NSAccessibility.post(
            element: panel, notification: .announcementRequested,
            userInfo: [.announcement: "Говорите", .priority: NSAccessibilityPriorityLevel.high.rawValue])
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [1.0, 1.8, 1.0]
        pop.keyTimes = [0, 0.4, 1]
        pop.duration = 0.25
        dot.add(pop, forKey: "pop")
    }

    func level(_ db: Double) {
        guard phase == .recording else { return }
        bars.push(db: db)
    }

    func showTranscribing() {
        guard phase == .recording else { return }
        phase = .transcribing
        label.stringValue = "Распознаю…"
        label.textColor = .labelColor
        dot.isHidden = true
        dot.removeAllAnimations()
        bars.isHidden = true
        spinner.startAnimation(nil)
        layout()
        place()
        content.setAccessibilityLabel("Диктовка: распознаю")
    }

    /// Режим «всю фразу»: распознанное видно здесь, пока не вставлено.
    func setTranscript(_ text: String) {
        guard phase == .recording || phase == .transcribing else { return }
        transcript.stringValue = text.trimmingCharacters(in: .whitespaces)
        layout()
        place()
    }

    func showNotice(_ message: String, symbolName: String = "exclamationmark.triangle.fill") {
        phase = .notice
        noticeTimer?.invalidate()
        transcript.stringValue = ""
        label.stringValue = message
        label.textColor = .labelColor
        dot.isHidden = true
        dot.removeAllAnimations()
        bars.isHidden = true
        spinner.stopAnimation(nil)
        cancelButton.isHidden = true
        symbol.isHidden = false
        symbol.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        symbol.contentTintColor = symbolName.hasPrefix("exclamation") ? .systemYellow : .secondaryLabelColor
        layout()
        present()
        content.setAccessibilityLabel("Диктовка: \(message)")
        NSAccessibility.post(
            element: panel, notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        noticeTimer = Timer.scheduledTimer(withTimeInterval: DictationIsland.noticeHold, repeats: false) {
            [weak self] _ in self?.hide()
        }
    }

    func hide() {
        guard phase != .hidden else { return }
        phase = .hidden
        noticeTimer?.invalidate()
        spinner.stopAnimation(nil)
        dot.removeAllAnimations()
        generation += 1
        let mine = generation
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.generation == mine else { return }
            self.panel.orderOut(nil)
        })
    }

    // MARK: - Раскладка

    private func setArmed(_ armed: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.backgroundColor =
            armed ? NSColor.systemRed.cgColor : NSColor.systemGray.withAlphaComponent(0.45).cgColor
        CATransaction.commit()
        dot.removeAllAnimations()
        guard armed, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.45
        pulse.duration = 0.95
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dot.add(pulse, forKey: "pulse")
    }

    private var hasTranscript: Bool { !transcript.stringValue.isEmpty }

    private func fittingSize() -> NSSize {
        if phase == .notice {
            let textWidth = ceil(label.attributedStringValue.size().width)
            return NSSize(width: min(420, max(DictationIsland.compactWidth, 12 + 16 + 8 + textWidth + 16)),
                          height: DictationIsland.rowHeight)
        }
        guard hasTranscript else {
            return NSSize(width: DictationIsland.compactWidth, height: DictationIsland.rowHeight)
        }
        let inner = DictationIsland.textWidth - 32
        transcript.preferredMaxLayoutWidth = inner
        let textHeight = min(36, ceil(transcript.sizeThatFits(NSSize(width: inner, height: 100)).height))
        return NSSize(width: DictationIsland.textWidth, height: DictationIsland.rowHeight + textHeight + 6)
    }

    private func layout() {
        let size = fittingSize()
        panel.setContentSize(size)
        background.layer?.cornerRadius = hasTranscript ? 16 : size.height / 2

        let row = DictationIsland.rowHeight
        let mid = row / 2  // строка управления — снизу
        let left: CGFloat = 16

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.position = CGPoint(x: left + 4, y: mid)
        CATransaction.commit()

        spinner.sizeToFit()
        spinner.frame.origin = CGPoint(x: left - 2, y: mid - spinner.frame.height / 2)
        symbol.frame = NSRect(x: left - 2, y: mid - 9, width: 18, height: 18)

        let cancelSize: CGFloat = 24
        cancelButton.frame = NSRect(x: size.width - 9 - cancelSize, y: mid - cancelSize / 2,
                                    width: cancelSize, height: cancelSize)

        bars.frame = NSRect(x: cancelButton.frame.minX - 8 - DictationLevelBars.width, y: mid - 10,
                            width: DictationLevelBars.width, height: 20)

        let labelX = left + 16
        let labelRight = phase == .recording && !bars.isHidden ? bars.frame.minX - 6 : cancelButton.frame.minX - 6
        let labelWidth = phase == .notice ? size.width - labelX - 16 : labelRight - labelX
        label.frame = NSRect(x: labelX, y: mid - 9, width: max(0, labelWidth), height: 18)

        transcript.isHidden = !hasTranscript
        if hasTranscript {
            transcript.frame = NSRect(x: left, y: row, width: size.width - 2 * left,
                                      height: size.height - row - 6)
        }
        panel.invalidateShadow()
    }

    private func targetScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    private func place() {
        guard let screen = targetScreen() else { return }
        let area = screen.visibleFrame  // без Dock и строки меню
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: round(area.midX - size.width / 2),
                                     y: area.minY + DictationIsland.bottomGap))
    }

    private func present() {
        generation += 1
        place()
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }
}

/*
 * Полоски уровня голоса. У колонки один уровень на 50 мс, а не спектр, как у
 * Handy, поэтому полоски показывают недавнюю историю: свежий уровень в центре,
 * более старые расходятся к краям.
 *
 * Шкала адаптивная. Фиксированная шкала Handy (−68…−30 дБ, ×1,3) рассчитана на
 * микрофон Mac; колонка с АРУ громче, и обычная речь стояла под потолком.
 * Поэтому низ шкалы — фон (быстро опускается, медленно поднимается), верх —
 * громкие места последних секунд (быстро поднимается, медленно спадает),
 * размах не меньше 24 дБ, чтобы тишина не раздувалась до полной высоты.
 */
final class DictationLevelBars: NSView {
    static let count = 9
    static let barWidth: CGFloat = 4
    static let gap: CGFloat = 3
    static var width: CGFloat { CGFloat(count) * barWidth + CGFloat(count - 1) * gap }

    var armed = false { didSet { needsDisplay = true } }
    private var history = [Double](repeating: 0, count: (count + 1) / 2)
    private var smoothed = 0.0
    private var floor: Double?
    private var peak = -90.0

    private static let minSpan = 24.0
    private static let floorRise = 0.02  // дБ за кадр 50 мс — 0,4 дБ/с
    private static let peakFall = 0.08  // дБ за кадр — 1,6 дБ/с

    func reset() {
        armed = false
        smoothed = 0
        floor = nil
        peak = -90
        history = [Double](repeating: 0, count: history.count)
        needsDisplay = true
    }

    func push(db: Double) {
        var low = floor ?? db
        low = db < low ? db : low + DictationLevelBars.floorRise
        floor = low
        peak = max(db, peak - DictationLevelBars.peakFall, low + DictationLevelBars.minSpan)
        let norm = max(0, min(1, (db - low - 3) / (peak - low)))
        let value = pow(norm, 1.3)
        smoothed = smoothed * 0.5 + value * 0.5
        history.insert(smoothed, at: 0)
        history.removeLast()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let center = DictationLevelBars.count / 2
        let color = armed ? NSColor.labelColor : NSColor.tertiaryLabelColor
        color.setFill()
        for index in 0..<DictationLevelBars.count {
            let age = abs(index - center)
            let value = history[min(age, history.count - 1)]
            let height = armed ? max(3, min(18, 3 + value * 15)) : 6
            let x = CGFloat(index) * (DictationLevelBars.barWidth + DictationLevelBars.gap)
            let rect = NSRect(x: x, y: (bounds.height - height) / 2,
                              width: DictationLevelBars.barWidth, height: height)
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
        }
    }
}
