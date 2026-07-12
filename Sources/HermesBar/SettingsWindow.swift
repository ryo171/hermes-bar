import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class SettingsWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 670),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "Hermes Bar"
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView())
        self.init(window: window)
    }
}

// Captures the next keypress and reports it as a HotKeyCombo.
final class HotKeyRecorder: ObservableObject {
    @Published var isRecording = false
    private var monitor: Any?
    var onCapture: ((HotKeyCombo) -> Void)?

    func start() {
        guard !isRecording else { return }
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            let flags = event.modifierFlags
            let combo = HotKeyCombo(
                keyCode: UInt32(event.keyCode),
                cmd: flags.contains(.command),
                shift: flags.contains(.shift),
                option: flags.contains(.option),
                control: flags.contains(.control))
            self.onCapture?(combo)
            self.stop()
            return nil   // swallow the event while recording
        }
    }

    func stop() {
        isRecording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}

final class SettingsModel: ObservableObject {
    @Published var language: AppLanguage { didSet { commit() } }
    @Published var themeName: String { didSet { commit() } }
    @Published var host: String { didSet { commit() } }
    @Published var hotKey: HotKeyCombo { didSet { commit() } }
    @Published var newWindowHotKey: HotKeyCombo { didSet { commit() } }
    @Published var layoutName: String { didSet { commit() } }
    @Published var iconStyle: String { didSet { commit() } }
    @Published var serverManagedSessions: Bool { didSet { commit() } }

    init() {
        let s = Settings.shared
        language = s.language
        themeName = s.themeName
        host = s.host
        hotKey = s.hotKey
        newWindowHotKey = s.newWindowHotKey
        layoutName = s.layoutName
        iconStyle = s.iconStyle
        serverManagedSessions = s.serverManagedSessions
    }

    private func commit() {
        let s = Settings.shared
        s.language = language
        s.themeName = themeName
        s.host = host
        s.hotKey = hotKey
        s.newWindowHotKey = newWindowHotKey
        s.layoutName = layoutName
        s.iconStyle = iconStyle
        s.serverManagedSessions = serverManagedSessions
        s.save()
    }
}

struct SettingsView: View {
    @StateObject private var model = SettingsModel()
    @StateObject private var recorder = HotKeyRecorder()
    @State private var hasCustomIcon = HermesIcon.hasCustomImage()
    @State private var iconPreview: NSImage? = HermesIcon.loadCustomPreview()

    private var ar: Bool { model.language == .arabic }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(ar ? "إعدادات Hermes Bar" : "Hermes Bar Settings")
                .font(.system(size: 18, weight: .bold))

            // Language
            row(ar ? "اللغة" : "Language") {
                Picker("", selection: $model.language) {
                    Text("العربية").tag(AppLanguage.arabic)
                    Text("English").tag(AppLanguage.english)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 180)
            }

            // Theme
            row(ar ? "الثيم" : "Theme") {
                Picker("", selection: $model.themeName) {
                    ForEach(Theme.all) { theme in
                        Text(theme.label).tag(theme.name)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
            }

            // Layout
            row(ar ? "التخطيط" : "Layout") {
                Picker("", selection: $model.layoutName) {
                    ForEach(PanelLayout.allCases, id: \.rawValue) { l in
                        Text(layoutLabel(l)).tag(l.rawValue)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
            }

            // Menu-bar icon
            row(ar ? "الأيقونة" : "Icon") {
                Picker("", selection: $model.iconStyle) {
                    ForEach(IconStyle.allCases, id: \.rawValue) { i in
                        Text(iconLabel(i)).tag(i.rawValue)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
                .disabled(hasCustomIcon)
            }

            // Custom icon image (overrides the styles above)
            row(ar ? "صورة مخصّصة" : "Custom image") {
                HStack(spacing: 10) {
                    if let p = iconPreview {
                        previewChip(p, bg: .white, tint: .black)
                        previewChip(p, bg: Color(white: 0.16), tint: .white)
                    }
                    Button(ar ? "اختر صورة…" : "Choose…") { chooseCustomIcon() }
                    if hasCustomIcon {
                        Button(ar ? "إزالة" : "Remove") {
                            HermesIcon.removeCustomImage()
                            hasCustomIcon = false
                            iconPreview = nil
                            NotificationCenter.default.post(name: Settings.didChangeNotification, object: nil)
                        }
                    }
                }
            }

            // Hotkey recorder
            row(ar ? "الاختصار" : "Hotkey") {
                HStack(spacing: 10) {
                    Text(model.hotKey.displayString)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.15)))

                    Button(recorder.isRecording
                           ? (ar ? "اضغط أي مفتاح…" : "Press keys…")
                           : (ar ? "تسجيل" : "Record")) {
                        recorder.onCapture = { combo in model.hotKey = combo }
                        recorder.start()
                    }
                    .disabled(recorder.isRecording)
                }
            }

            // New-window hotkey recorder
            row(ar ? "نافذة جديدة" : "New window") {
                HStack(spacing: 10) {
                    Text(model.newWindowHotKey.displayString)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.15)))

                    Button(recorder.isRecording
                           ? (ar ? "اضغط أي مفتاح…" : "Press keys…")
                           : (ar ? "تسجيل" : "Record")) {
                        recorder.onCapture = { combo in model.newWindowHotKey = combo }
                        recorder.start()
                    }
                    .disabled(recorder.isRecording)
                }
            }

            // Host
            row(ar ? "عنوان هيرميس" : "Hermes host") {
                TextField("http://localhost:8642", text: $model.host)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }

            // Server-managed sessions (X-Hermes-Session-Id)
            row(ar ? "جلسات مشتركة" : "Shared sessions") {
                Toggle("", isOn: $model.serverManagedSessions)
                    .labelsHidden()
                    .help(ar ? "يخلي محادثات النافذة جلسات هيرميس حقيقية تكمّلها في الديسكتوب. أطفئه لخوادم OpenAI العامة."
                             : "Make panel chats real Hermes sessions you can continue in Desktop. Turn off for generic OpenAI hosts.")
            }

            Divider()

            Text(ar
                 ? "التغييرات تُحفظ تلقائياً. تأكد أن هيرميس شغّال: hermes gateway"
                 : "Changes save automatically. Make sure Hermes is running: hermes gateway")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            Spacer()
        }
        .padding(24)
        .frame(width: 440, height: 670, alignment: .topLeading)
        .environment(\.layoutDirection, ar ? .rightToLeft : .leftToRight)
    }

    private func previewChip(_ img: NSImage, bg: Color, tint: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5).fill(bg)
            Image(nsImage: img)
                .resizable()
                .renderingMode(.template)
                .interpolation(.high)
                .frame(width: 18, height: 18)
                .foregroundColor(tint)
        }
        .frame(width: 26, height: 26)
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.secondary.opacity(0.3)))
    }

    private func chooseCustomIcon() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image]
        panel.begin { resp in
            if resp == .OK, let url = panel.url, HermesIcon.installCustomImage(from: url) {
                hasCustomIcon = true
                iconPreview = HermesIcon.loadCustomPreview()
                NotificationCenter.default.post(name: Settings.didChangeNotification, object: nil)
            }
        }
    }

    private func layoutLabel(_ l: PanelLayout) -> String {
        switch l {
        case .classic: return ar ? "كلاسيكي" : "Classic"
        case .chat:    return ar ? "محادثة" : "Chat"
        case .rail:    return ar ? "شريط جانبي" : "Rail"
        case .minimal: return ar ? "تركيز" : "Minimal"
        }
    }

    private func iconLabel(_ i: IconStyle) -> String {
        switch i {
        case .winged: return ar ? "مجنّحة" : "Winged"
        case .spark:  return ar ? "لوحة + ومضة" : "Spark"
        case .comet:  return ar ? "مذنّب" : "Comet"
        case .prompt: return ar ? "مؤشّر أمر" : "Prompt"
        case .hermes: return ar ? "هيرميس" : "Hermes"
        }
    }

    @ViewBuilder
    private func row<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 110, alignment: ar ? .trailing : .leading)
            content()
            Spacer()
        }
    }
}
