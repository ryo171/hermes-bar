import AppKit
import SwiftUI

final class SettingsWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 560),
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

    init() {
        let s = Settings.shared
        language = s.language
        themeName = s.themeName
        host = s.host
        hotKey = s.hotKey
        newWindowHotKey = s.newWindowHotKey
        layoutName = s.layoutName
        iconStyle = s.iconStyle
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
        s.save()
    }
}

struct SettingsView: View {
    @StateObject private var model = SettingsModel()
    @StateObject private var recorder = HotKeyRecorder()

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

            Divider()

            Text(ar
                 ? "التغييرات تُحفظ تلقائياً. تأكد أن هيرميس شغّال: hermes gateway"
                 : "Changes save automatically. Make sure Hermes is running: hermes gateway")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            Spacer()
        }
        .padding(24)
        .frame(width: 440, height: 560, alignment: .topLeading)
        .environment(\.layoutDirection, ar ? .rightToLeft : .leftToRight)
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
