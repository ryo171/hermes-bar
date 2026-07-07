import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let hotKey = GlobalHotKey()
    private var panelController: AskPanelController?
    private var settingsWindow: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        registerHotKey()

        // React to settings changes (hotkey re-record, theme, language).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsChanged),
            name: Settings.didChangeNotification,
            object: nil
        )
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
        let s = Settings.shared
        let ar = s.language == .arabic
        let menu = NSMenu()

        let askScreen = NSMenuItem(
            title: ar ? "اسأل عن شاشتي" : "Ask about my screen",
            action: #selector(askAboutScreen), keyEquivalent: ""
        )
        askScreen.target = self
        menu.addItem(askScreen)

        let askText = NSMenuItem(
            title: ar ? "اسأل (نص فقط)" : "Ask (text only)",
            action: #selector(askTextOnly), keyEquivalent: ""
        )
        askText.target = self
        menu.addItem(askText)

        menu.addItem(.separator())

        let settings = NSMenuItem(
            title: ar ? "الإعدادات…" : "Settings…",
            action: #selector(openSettings), keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)

        let check = NSMenuItem(
            title: ar ? "فحص الاتصال" : "Check connection",
            action: #selector(checkConnection), keyEquivalent: ""
        )
        check.target = self
        menu.addItem(check)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: ar ? "إنهاء Hermes Bar" : "Quit Hermes Bar",
            action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"
        )
        menu.addItem(quit)

        statusItem.menu = menu
    }

    // MARK: - Hotkey

    private func registerHotKey() {
        let combo = Settings.shared.hotKey
        hotKey.register(keyCode: combo.keyCode, modifiers: combo.carbonModifiers) { [weak self] in
            self?.togglePanel(withScreenshot: true)
        }
    }

    @objc private func settingsChanged() {
        rebuildMenu()
        registerHotKey()          // re-register in case the combo changed
        panelController?.applyTheme()
    }

    // MARK: - Actions

    @objc private func askAboutScreen() { showPanel(withScreenshot: true) }
    @objc private func askTextOnly()    { showPanel(withScreenshot: false) }

    @objc private func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController()
        }
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

    private func showPanel(withScreenshot: Bool) {
        if panelController == nil {
            panelController = AskPanelController()
        }
        panelController?.present(withScreenshot: withScreenshot)
    }

    private func togglePanel(withScreenshot: Bool) {
        if let pc = panelController, pc.isVisible {
            pc.dismiss()
        } else {
            showPanel(withScreenshot: withScreenshot)
        }
    }
}
