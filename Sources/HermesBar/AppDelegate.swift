import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private let hotKey = GlobalHotKey(id: 1)
    private let newWindowHotKey = GlobalHotKey(id: 2)
    private let closeHotKey = GlobalHotKey(id: 3)
    // Every open conversation window. The ONLY things that append here are the
    // explicit creators (New-conversation hotkey/menu/icon + Ask menu when nothing
    // is open). Show/Hide never creates; Close destroys and removes.
    private var windows: [AskPanelController] = []
    private weak var pendingResultController: AskPanelController?
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

        // The panel's "new window" icon asks us to spawn an independent Hermes.
        NotificationCenter.default.addObserver(
            self, selector: #selector(spawnWindow),
            name: .hbSpawnWindow, object: nil
        )

        // Remember which window finished a notify-worthy task, so tapping the
        // notification brings *that* window forward (primary or a spawned one).
        NotificationCenter.default.addObserver(
            forName: .hbPendingResult, object: nil, queue: .main
        ) { [weak self] note in
            self?.pendingResultController = note.object as? AskPanelController
        }
    }

    // MARK: - Main menu (standard editing shortcuts)

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        // No key equivalent here — the configurable global hotkey handles it,
        // and a matching menu shortcut would spawn two windows at once.
        let newWin = NSMenuItem(title: "New Hermes Window",
                                action: #selector(spawnWindow), keyEquivalent: "")
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

        menu.addItem(.separator())

        // The three strict window actions, each labelled with its shortcut.
        let winKey = Settings.shared.newWindowHotKey.displayString
        let newConvo = NSMenuItem(title: (ar ? "محادثة جديدة" : "New conversation") + "  (\(winKey))",
                                  action: #selector(spawnWindow), keyEquivalent: "")
        newConvo.target = self
        menu.addItem(newConvo)

        let toggleKey = Settings.shared.hotKey.displayString
        let showHide = NSMenuItem(title: (ar ? "إظهار/إخفاء" : "Show/Hide") + "  (\(toggleKey))",
                                  action: #selector(menuToggle), keyEquivalent: "")
        showHide.target = self
        menu.addItem(showHide)

        let closeKey = Settings.shared.closeHotKey.displayString
        let closeChat = NSMenuItem(title: (ar ? "إغلاق المحادثة" : "Close conversation") + "  (\(closeKey))",
                                   action: #selector(menuClose), keyEquivalent: "")
        closeChat.target = self
        menu.addItem(closeChat)

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
        let winCombo = Settings.shared.newWindowHotKey
        newWindowHotKey.register(keyCode: winCombo.keyCode, modifiers: winCombo.carbonModifiers) { [weak self] in
            self?.spawnWindow()
        }
        let closeCombo = Settings.shared.closeHotKey
        closeHotKey.register(keyCode: closeCombo.keyCode, modifiers: closeCombo.carbonModifiers) { [weak self] in
            self?.closeConversation()
        }
    }

    // Close = permanently DESTROY only the focused window (the one with the text
    // cursor / key focus). Not "hide" — it's gone for good and won't come back on
    // the next Show. Falls back to the frontmost visible window if none is key.
    private func closeConversation() {
        guard let target = windows.first(where: { $0.isKey })
                        ?? windows.last(where: { $0.isVisible }) else { return }
        target.destroy()   // its onClosed callback removes it from `windows`
    }

    @objc private func settingsChanged() {
        rebuildMenu()
        registerHotKey()
        statusItem.button?.image = HermesIcon.statusBarImage()
        statusItem.button?.image?.isTemplate = true
        windows.forEach { $0.applyTheme() }
    }

    // MARK: - Actions

    // Ask menu: reuse the focused/frontmost open window (just flip its screenshot
    // pref) so it doesn't proliferate; create one only if nothing is open.
    @objc private func askAboutScreen() { askOrCreate(screenshot: true) }
    @objc private func askTextOnly()    { askOrCreate(screenshot: false) }

    private func askOrCreate(screenshot: Bool) {
        // Reuse any existing window (key → visible → any) so Ask never proliferates;
        // create one only when nothing exists at all.
        if let c = windows.first(where: { $0.isKey })
                ?? windows.last(where: { $0.isVisible })
                ?? windows.first {
            c.setScreenshot(screenshot)
            c.present()
        } else {
            newWindow(screenshot: screenshot)
        }
    }

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

    // The ONE creator. Every new window flows through here and registers an
    // onClosed callback so it's removed from `windows` when destroyed.
    private func newWindow(screenshot: Bool) {
        let c = AskPanelController()
        c.setScreenshot(screenshot)
        c.onClosed = { [weak self, weak c] in
            guard let self = self, let c = c else { return }
            self.windows.removeAll { $0 === c }
            if self.pendingResultController === c { self.pendingResultController = nil }
        }
        windows.append(c)
        c.present()
    }

    // STRICT show/hide: ONLY toggles windows that already exist — never creates.
    // Any visible → hide them all (preserving their positions + chats); all hidden
    // → bring them back where they were; none exist → no-op. Repeated presses can
    // never spawn or duplicate windows.
    private func togglePanel() {
        let visible = windows.filter { $0.isVisible }
        if !visible.isEmpty {
            // Focused window (text cursor / key focus) → hide ONLY that one, the
            // rest stay put. No focused window (app in background) → hide them all.
            if let focused = visible.first(where: { $0.isKey }) {
                focused.dismiss()
            } else {
                visible.forEach { $0.dismiss() }
            }
        } else {
            windows.forEach { $0.present() }
        }
    }

    // Menu wrappers for the two hotkey-driven actions (so they're discoverable).
    @objc private func menuToggle() { togglePanel() }
    @objc private func menuClose()  { closeConversation() }

    // New conversation — a fully independent Hermes window (own thread + session).
    @objc private func spawnWindow() { newWindow(screenshot: false) }

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
        (pendingResultController ?? windows.last)?.presentShowingResult()
        completionHandler()
    }
}
