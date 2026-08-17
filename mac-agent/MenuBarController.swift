import AppKit
import ServiceManagement

/*
 * Значок в строке состояния: заряды трёх устройств, слой, выбранный выход и
 * управление самим агентом.
 *
 * Данные берутся из слепка, который агент вычитал с донгла в паузе печати, —
 * при открытии меню в эфир не лезем. Поэтому показанное может отставать на
 * один цикл опроса, и это осознанный размен в пользу отзывчивости набора.
 */
final class MenuBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var state: DongleState?
    private var linkUp = false

    var isPaused = false

    override init() {
        super.init()

        item.button?.image = NSImage(
            systemSymbolName: "keyboard", accessibilityDescription: "Sweep Dongle")
        item.button?.imagePosition = .imageLeading

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu

        refreshTitle()
    }

    func update(state: DongleState?, linkUp: Bool) {
        self.state = state
        self.linkUp = linkUp
        refreshTitle()
    }

    private func refreshTitle() {
        guard linkUp, let lowest = state?.lowestBattery else {
            item.button?.title = ""
            return
        }

        item.button?.title = " \(lowest)%"
    }

    // MARK: - Меню

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        guard linkUp, let state else {
            menu.addItem(disabled("Донгл не найден"))
            addControls(to: menu)
            return
        }

        menu.addItem(disabled("Левая половина     \(DongleState.percentText(state.battLeft))"))
        menu.addItem(disabled("Правая половина  \(DongleState.percentText(state.battRight))"))
        menu.addItem(disabled("Донгл                    \(DongleState.percentText(state.battDongle))"))
        menu.addItem(.separator())
        menu.addItem(disabled("Слой: \(state.layerName)"))
        menu.addItem(disabled("Выход: \(state.outputDescription)"))

        addControls(to: menu)
    }

    private func addControls(to menu: NSMenu) {
        menu.addItem(.separator())

        let pause = NSMenuItem(
            title: isPaused ? "Возобновить отправку" : "Приостановить отправку",
            action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)

        let login = NSMenuItem(
            title: "Запускать при входе", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Завершить", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        return entry
    }

    @objc private func togglePause() { isPaused.toggle() }

    @objc private func toggleLoginItem() { LoginItem.setEnabled(!LoginItem.isEnabled) }

    @objc private func quit() { NSApplication.shared.terminate(nil) }
}

/*
 * Автозапуск через SMAppService: система сама поднимает бандл при входе, и
 * запрос доступа к Bluetooth привязывается к нему, а не к терминалу.
 *
 * Заодно снимаем прежний LaunchAgent, если он остался: две копии агента
 * дрались бы за одно соединение с донглом.
 */
enum LoginItem {
    private static let legacyPlist = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/ru.pazdnikoff.sweepdongle.agent.plist")

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                removeLegacyLaunchAgent()
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log("автозапуск: \(error.localizedDescription)")
        }
    }

    private static func removeLegacyLaunchAgent() {
        guard FileManager.default.fileExists(atPath: legacyPlist.path) else { return }

        let uid = getuid()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["bootout", "gui/\(uid)/ru.pazdnikoff.sweepdongle.agent"]
        try? task.run()
        task.waitUntilExit()

        try? FileManager.default.removeItem(at: legacyPlist)
        log("снят прежний LaunchAgent, чтобы не было двух копий")
    }
}

/*
 * Первый запуск: предложить переехать в /Applications и включить автозапуск.
 * Спрашиваем ровно один раз — отказ запоминается, чтобы не надоедать.
 */
enum FirstRun {
    /*
     * Два отдельных флага, а не один общий, и это важно: после переезда в
     * /Applications приложение перезапускается, и с общим флагом вопрос про
     * автозапуск уже не задавался бы — он был бы «отмечен как заданный» ещё до
     * перезапуска.
     */
    private static let askedInstallKey = "ru.pazdnikoff.sweepdongle.askedInstall"
    private static let askedLoginKey = "ru.pazdnikoff.sweepdongle.askedLogin"

    static func askIfNeeded() {
        let inApplications = Bundle.main.bundlePath.hasPrefix("/Applications/")

        if !inApplications, !UserDefaults.standard.bool(forKey: askedInstallKey) {
            UserDefaults.standard.set(true, forKey: askedInstallKey)
            offerInstall()
            return
        }

        guard !UserDefaults.standard.bool(forKey: askedLoginKey) else { return }
        UserDefaults.standard.set(true, forKey: askedLoginKey)
        offerLoginItem()
    }

    private static func offerInstall() {
        let alert = NSAlert()
        alert.messageText = "Переместить в «Программы»?"
        alert.informativeText =
            "Sweep Dongle Agent сейчас запущен не из папки «Программы». "
            + "Перенести его туда и перезапустить оттуда?"
        alert.addButton(withTitle: "Переместить")
        alert.addButton(withTitle: "Не сейчас")

        guard alert.runModal() == .alertFirstButtonReturn else {
            askIfNeeded()  // переезд отклонён — сразу спрашиваем про автозапуск
            return
        }

        install()
    }

    private static func install() {
        let source = URL(fileURLWithPath: Bundle.main.bundlePath)
        let destination = URL(fileURLWithPath: "/Applications")
            .appendingPathComponent(source.lastPathComponent)

        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Не удалось переместить"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            askIfNeeded()
            return
        }

        // Запускаем копию и уходим: обновлять бандл под собой нельзя.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", destination.path]
        try? task.run()

        NSApplication.shared.terminate(nil)
    }

    private static func offerLoginItem() {
        guard !LoginItem.isEnabled else { return }

        let alert = NSAlert()
        alert.messageText = "Запускать при входе в систему?"
        alert.informativeText =
            "Агент будет подниматься автоматически и показывать заряд клавиатуры "
            + "в строке состояния. Отключить можно в его же меню."
        alert.addButton(withTitle: "Запускать")
        alert.addButton(withTitle: "Не надо")

        if alert.runModal() == .alertFirstButtonReturn {
            LoginItem.setEnabled(true)
        }
    }
}
