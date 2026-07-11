import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private let hotKey = GlobalHotKey()
    private var panelController: AskPanelController?
    private var extraPanels: [AskPanelController] = []
    private var settingsWindow: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()          // enables Cmd+C / V / X / A / Z in text fields
        UNUserNotificationCenter.current().delegate = self
        Notifier.requestAuth()   // for "scoped pin" completion alerts
        setupStatusItem()
        registerHotKey()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsChanged),
            name: Settings.didChangeNotification,
            object: nil
        )
    }

    // MARK: - Main menu (standard editing shortcuts)

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        let newWin = NSMenuItem(title: "New Hermes Window",
                                action: #selector(spawnWindow), keyEquivalent: "n")
        newWin.keyEquivalentModifierMask = [.command, .shift]
        newWin.target = self
        appMenu.addItem(newWin)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Hermes Bar",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Menu bar item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = HermesIcon.statusBarImage()
            button.image?.isTemplate = true
            button.toolTip = "Hermes Bar"
        }
        rebuildMenu()
    }

    private func rebuildMenu() {
        let ar = Settings.shared.language == .arabic
        let menu = NSMenu()

        let askScreen = NSMenuItem(title: ar ? "اسأل عن شاشتي" : "Ask about my screen",
                                   action: #selector(askAboutScreen), keyEquivalent: "")
        askScreen.target = self
        menu.addItem(askScreen)

        let askText = NSMenuItem(title: ar ? "اسأل (نص فقط)" : "Ask (text only)",
                                 action: #selector(askTextOnly), keyEquivalent: "")
        askText.target = self
        menu.addItem(askText)

        let newWindow = NSMenuItem(title: ar ? "نافذة جديدة (⌘⇧N)" : "New window (⌘⇧N)",
                                   action: #selector(spawnWindow), keyEquivalent: "")
        newWindow.target = self
        menu.addItem(newWindow)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: ar ? "الإعدادات…" : "Settings…",
                                  action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let check = NSMenuItem(title: ar ? "فحص الاتصال" : "Check connection",
                               action: #selector(checkConnection), keyEquivalent: "")
        check.target = self
        menu.addItem(check)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: ar ? "إنهاء Hermes Bar" : "Quit Hermes Bar",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    // MARK: - Hotkey

    private func registerHotKey() {
        let combo = Settings.shared.hotKey
        hotKey.register(keyCode: combo.keyCode, modifiers: combo.carbonModifiers) { [weak self] in
            self?.togglePanel()
        }
    }

    @objc private func settingsChanged() {
        rebuildMenu()
        registerHotKey()
        panelController?.applyTheme()
    }

    // MARK: - Actions

    @objc private func askAboutScreen() { showPanel(screenshot: true) }
    @objc private func askTextOnly()    { showPanel(screenshot: false) }

    @objc private func openSettings() {
        if settingsWindow == nil { settingsWindow = SettingsWindowController() }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func checkConnection() {
        HermesClient.shared.health { ok in
            let ar = Settings.shared.language == .arabic
            let alert = NSAlert()
            if ok {
                alert.messageText = ar ? "متصل ✅" : "Connected ✅"
                alert.informativeText = ar
                    ? "هيرميس شغّال على \(Settings.shared.host)"
                    : "Hermes is running at \(Settings.shared.host)"
            } else {
                alert.messageText = ar ? "لا يمكن الوصول لهيرميس" : "Can't reach Hermes"
                alert.informativeText = ar
                    ? "هل الـ gateway شغّال؟ شغّله بـ:\n    hermes gateway"
                    : "Is the gateway running? Start it with:\n    hermes gateway"
            }
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    // MARK: - Panel

    private func ensureController() -> AskPanelController {
        if panelController == nil { panelController = AskPanelController() }
        return panelController!
    }

    private func showPanel(screenshot: Bool) {
        let c = ensureController()
        c.setScreenshot(screenshot)
        c.present()
    }

    private func togglePanel() {
        let c = ensureController()
        if c.isVisible { c.dismiss() } else { c.present() }
    }

    // A second, fully independent Hermes window: its own conversation and thread,
    // same local gateway. Independent requests → no effect on answer quality.
    @objc private func spawnWindow() {
        extraPanels.removeAll { !$0.isVisible }   // drop closed ones so they don't pile up
        let c = AskPanelController()
        c.setScreenshot(false)
        extraPanels.append(c)
        c.present()
    }

    // MARK: - Notifications (scoped pin)

    // Show the banner even while our app is frontmost.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // Tapping the "task done" notification reopens the panel with the result.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        panelController?.presentShowingResult()
        completionHandler()
    }
}
