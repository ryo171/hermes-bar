import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers
import UserNotifications

// Pin behavior: off = click-away closes; absolute = follows you everywhere;
// scoped = you can leave, and a notification fires when the task finishes.
enum PinMode: String { case off, absolute, scoped }

enum Notifier {
    static func requestAuth() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    static func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}

struct AttachmentItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    var name: String { url.lastPathComponent }
    var isImage: Bool {
        ["png","jpg","jpeg","gif","webp","heic","bmp","tiff","tif"].contains(url.pathExtension.lowercased())
    }
    var isDirectory: Bool {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return isDir.boolValue
    }
    var symbol: String { isImage ? "photo" : (isDirectory ? "folder" : "doc") }
}

func mimeType(ext: String) -> String {
    switch ext.lowercased() {
    case "png": return "image/png"
    case "jpg", "jpeg": return "image/jpeg"
    case "gif": return "image/gif"
    case "webp": return "image/webp"
    case "heic": return "image/heic"
    case "bmp": return "image/bmp"
    case "tiff", "tif": return "image/tiff"
    default: return "application/octet-stream"
    }
}

func imageDataURL(for url: URL, maxBytes: Int = 5_000_000) -> String? {
    guard let data = try? Data(contentsOf: url), data.count <= maxBytes else { return nil }
    return "data:\(mimeType(ext: url.pathExtension));base64,\(data.base64EncodedString())"
}

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = 18
        v.layer?.masksToBounds = true
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

final class FloatingPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .resizable, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        minSize = NSSize(width: 460, height: 240)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class AskViewModel: ObservableObject {
    @Published var input: String = ""
    @Published var response: String = ""
    @Published var errorText: String = ""
    @Published var isLoading: Bool = false
    @Published var pinMode: PinMode = PinMode(rawValue: UserDefaults.standard.string(forKey: "hb.pinmode") ?? "off") ?? .off
    @Published var attachments: [AttachmentItem] = []
    @Published var mode: String = UserDefaults.standard.string(forKey: "hb.mode") ?? "fast"
    @Published var withScreenshot: Bool =
        (UserDefaults.standard.object(forKey: "hb.withshot") as? Bool) ?? true

    @Published var theme: Theme = Settings.shared.theme
    @Published var isArabic: Bool = Settings.shared.language == .arabic

    var onClose: (() -> Void)?

    func setMode(_ m: String) {
        mode = m
        UserDefaults.standard.set(m, forKey: "hb.mode")
    }

    private func fastHost() -> String {
        let h = UserDefaults.standard.string(forKey: "hb.fasthost") ?? ""
        return h.isEmpty ? Settings.shared.host : h
    }

    func setWithScreenshot(_ on: Bool) {
        withScreenshot = on
        UserDefaults.standard.set(on, forKey: "hb.withshot")
    }

    func cyclePinMode() {
        let next: PinMode = (pinMode == .off) ? .absolute : (pinMode == .absolute ? .scoped : .off)
        pinMode = next
        UserDefaults.standard.set(next.rawValue, forKey: "hb.pinmode")
    }

    func addAttachment(_ url: URL) {
        if !attachments.contains(where: { $0.url == url }) {
            attachments.append(AttachmentItem(url: url))
        }
    }

    func removeAttachment(_ item: AttachmentItem) {
        attachments.removeAll { $0.id == item.id }
    }

    func refreshFromSettings() {
        theme = Settings.shared.theme
        isArabic = Settings.shared.language == .arabic
    }

    func reset() {
        input = ""
        response = ""
        errorText = ""
        isLoading = false
        attachments = []
        refreshFromSettings()
    }

    func send() {
        let q0 = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!q0.isEmpty || !attachments.isEmpty), !isLoading else { return }
        isLoading = true
        errorText = ""
        response = ""

        let atts = attachments
        attachments = []
        let wantsShot = withScreenshot
        let ar = isArabic

        let fast = (mode == "fast")
        let effort = fast ? "low" : "high"
        let detail = "high"
        let shotMax = 0
        let host = fast ? fastHost() : Settings.shared.host

        DispatchQueue.global(qos: .userInitiated).async {
            var images: [String] = []
            if wantsShot, let shot = Screenshot.captureBase64PNG(maxPx: shotMax) {
                images.append("data:image/png;base64,\(shot)")
            }
            var pathNotes: [String] = []
            for a in atts {
                if a.isImage, let durl = imageDataURL(for: a.url) {
                    images.append(durl)
                } else {
                    pathNotes.append(a.url.path)
                }
            }

            var text = q0
            if text.isEmpty {
                text = ar ? "شوف المرفقات وساعدني." : "Take a look at the attachment(s) and help me."
            }
            if !pathNotes.isEmpty {
                let label = ar
                    ? "ملفات/مجلدات مرفقة (افتحها بأدواتك):"
                    : "Attached files/folders (open them with your tools):"
                text += "\n\n" + label + "\n" + pathNotes.map { "- \($0)" }.joined(separator: "\n")
            }

            HermesClient.shared.askStream(
                host: host,
                question: text,
                imageDataURLs: images,
                imageDetail: detail,
                reasoningEffort: effort,
                onDelta: { [weak self] (piece: String) in
                    guard let self = self else { return }
                    if self.isLoading { self.isLoading = false }
                    self.response += piece
                },
                onDone: { [weak self] (err: Error?) in
                    guard let self = self else { return }
                    self.isLoading = false
                    if let err = err, self.response.isEmpty {
                        self.errorText = err.localizedDescription
                    }
                    if self.pinMode == .scoped {
                        let summary = self.errorText.isEmpty ? String(self.response.prefix(120)) : self.errorText
                        Notifier.notify(
                            title: self.isArabic ? "هيرميس خلّص ✅" : "Hermes finished ✅",
                            body: summary.isEmpty ? (self.isArabic ? "تمّت المهمة" : "Task done") : summary
                        )
                    }
                }
            )
        }
    }
}

final class AskPanelController: NSObject, NSWindowDelegate {
    private var panel: FloatingPanel?
    private let viewModel = AskViewModel()
    private let defaultSize = NSSize(width: 720, height: 480)

    var isVisible: Bool { panel?.isVisible ?? false }

    func setScreenshot(_ on: Bool) { viewModel.setWithScreenshot(on) }

    private func savedSize() -> NSSize {
        let d = UserDefaults.standard
        let w = d.double(forKey: "hb.win.w")
        let h = d.double(forKey: "hb.win.h")
        if w >= 460, h >= 240 { return NSSize(width: w, height: h) }
        return defaultSize
    }

    private func ensurePanel() {
        if panel == nil {
            let rect = NSRect(origin: .zero, size: savedSize())
            let p = FloatingPanel(contentRect: rect)
            p.contentView = NSHostingView(rootView: AskView(vm: viewModel))
            p.delegate = self
            panel = p
        }
    }

    func present() {
        viewModel.reset()
        viewModel.onClose = { [weak self] in self?.dismiss() }
        ensurePanel()
        position(panel!)
        NSApp.activate(ignoringOtherApps: true)
        panel!.makeKeyAndOrderFront(nil)
    }

    func presentShowingResult() {
        viewModel.onClose = { [weak self] in self?.dismiss() }
        ensurePanel()
        position(panel!)
        NSApp.activate(ignoringOtherApps: true)
        panel!.makeKeyAndOrderFront(nil)
    }

    func dismiss() { panel?.orderOut(nil) }

    func applyTheme() { viewModel.refreshFromSettings() }

    func windowDidResignKey(_ notification: Notification) {
        if viewModel.pinMode == .absolute { return }
        DispatchQueue.main.async { [weak self] in self?.dismiss() }
    }

    func windowDidResize(_ notification: Notification) {
        guard let size = panel?.frame.size else { return }
        UserDefaults.standard.set(Double(size.width), forKey: "hb.win.w")
        UserDefaults.standard.set(Double(size.height), forKey: "hb.win.h")
    }

    private func position(_ panel: NSPanel) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let x = visible.midX - size.width / 2
        let y = visible.maxY - size.height - visible.height * 0.14
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

struct AskView: View {
    @ObservedObject var vm: AskViewModel
    @FocusState private var inputFocused: Bool
    @State private var dropTargeted = false

    private var t: Theme { vm.theme }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            inputRow
            if !vm.attachments.isEmpty { attachmentsRow }
            Divider().opacity(0.15)
            contentArea
            modeBar
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(background)
        .overlay(dropHighlight)
        .environment(\.layoutDirection, vm.isArabic ? .rightToLeft : .leftToRight)
        .onAppear { inputFocused = true }
        .onExitCommand { vm.onClose?() }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
        }
    }

    @ViewBuilder private var background: some View {
        if t.isGlass {
            VisualEffectBackground()
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                )
        } else {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(t.background)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(t.accent.opacity(0.25), lineWidth: 1)
                )
        }
    }

    @ViewBuilder private var dropHighlight: some View {
        if dropTargeted {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(t.accent, lineWidth: 2)
        }
    }

    private var placeholder: String {
        vm.isArabic ? "وش تحتاج مساعدة فيه؟" : "What do you need help with?"
    }

    private var inputRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundColor(t.accent)
                .font(.system(size: 18, weight: .semibold))

            TextField(placeholder, text: $vm.input)
                .textFieldStyle(.plain)
                .font(.system(size: 18))
                .foregroundColor(t.textPrimary)
                .focused($inputFocused)
                .onSubmit { vm.send() }

            Button(action: openFilePicker) {
                Image(systemName: "paperclip")
                    .font(.system(size: 15))
                    .foregroundColor(t.textSecondary)
            }
            .buttonStyle(.plain)
            .help(vm.isArabic ? "إرفاق ملف أو صورة" : "Attach file or image")

            Button(action: { vm.setWithScreenshot(!vm.withScreenshot) }) {
                Image(systemName: vm.withScreenshot ? "eye.fill" : "eye.slash")
                    .font(.system(size: 15))
                    .foregroundColor(vm.withScreenshot ? t.accent : t.textSecondary)
            }
            .buttonStyle(.plain)
            .help(vm.isArabic ? "رؤية الشاشة (أسرع لو مطفّية)" : "See screen (faster when off)")

            Button(action: { vm.cyclePinMode() }) {
                Image(systemName: pinIcon)
                    .font(.system(size: 15))
                    .foregroundColor(vm.pinMode == .off ? t.textSecondary : t.accent)
            }
            .buttonStyle(.plain)
            .help(pinHelp)

            Button(action: openHermesDesktop) {
                Image(systemName: "macwindow.on.rectangle")
                    .font(.system(size: 15))
                    .foregroundColor(t.textSecondary)
            }
            .buttonStyle(.plain)
            .help(vm.isArabic ? "افتح هيرميس ديسكتوب" : "Open Hermes Desktop")

            Button(action: { vm.send() }) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(canSend ? t.accent : t.textSecondary.opacity(0.4))
            }
            .buttonStyle(.plain)
            .disabled(!canSend || vm.isLoading)
        }
    }

    private var canSend: Bool {
        !vm.input.trimmingCharacters(in: .whitespaces).isEmpty || !vm.attachments.isEmpty
    }

    private var attachmentsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(vm.attachments) { att in
                    HStack(spacing: 5) {
                        Image(systemName: att.symbol)
                            .font(.system(size: 11))
                            .foregroundColor(t.accent)
                        Text(att.name)
                            .font(.system(size: 12))
                            .foregroundColor(t.textPrimary)
                            .lineLimit(1)
                        Button(action: { vm.removeAttachment(att) }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(t.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(t.surface))
                }
            }
        }
        .frame(maxHeight: 30)
    }

    private var contentArea: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if vm.isLoading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(vm.isArabic ? "هيرميس يفكّر…" : "Hermes is thinking…")
                            .font(.system(size: 14))
                            .foregroundColor(t.textSecondary)
                    }
                }
                if !vm.errorText.isEmpty {
                    Text(vm.errorText)
                        .font(.system(size: 14))
                        .foregroundColor(.red)
                        .textSelection(.enabled)
                }
                if !vm.response.isEmpty {
                    Text(vm.response)
                        .font(.system(size: 16))
                        .foregroundColor(t.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var modeBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 12))
                .foregroundColor(t.textSecondary)

            ForEach(["fast", "quality"], id: \.self) { m in
                let selected = vm.mode == m
                Button(action: { vm.setMode(m) }) {
                    Text(modeLabel(m))
                        .font(.system(size: 12, weight: selected ? .bold : .regular))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(selected ? t.accent.opacity(0.28) : Color.clear)
                        )
                        .foregroundColor(selected ? t.textPrimary : t.textSecondary)
                }
                .buttonStyle(.plain)
            }

            Text(modeHint)
                .font(.system(size: 10))
                .foregroundColor(t.textSecondary.opacity(0.7))
                .lineLimit(1)

            Spacer()
        }
    }

    private var pinIcon: String {
        switch vm.pinMode {
        case .off: return "pin"
        case .absolute: return "pin.fill"
        case .scoped: return "bell.fill"
        }
    }

    private var pinHelp: String {
        switch vm.pinMode {
        case .off:
            return vm.isArabic ? "غير مثبّت — اضغط: تثبيت مطلق" : "Not pinned — click: pin everywhere"
        case .absolute:
            return vm.isArabic ? "مثبّت معك في كل مكان — اضغط: تثبيت خاص (يشعرك عند الانتهاء)" : "Pinned everywhere — click: scoped"
        case .scoped:
            return vm.isArabic ? "تثبيت خاص — يشتغل ويشعرك عند الانتهاء — اضغط: إلغاء" : "Scoped — notifies when done — click: off"
        }
    }

    private func modeLabel(_ m: String) -> String {
        if m == "fast" { return vm.isArabic ? "سريع" : "Fast" }
        return vm.isArabic ? "جودة" : "Quality"
    }

    private var modeHint: String {
        if vm.mode == "fast" {
            return vm.isArabic ? "أسرع · تفكير أقل" : "faster · less thinking"
        }
        return vm.isArabic ? "أعمق · تفكير أعلى" : "deeper · more thinking"
    }

    private func openHermesDesktop() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", "Hermes"]
        try? task.run()
        vm.onClose?()
    }

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.begin { resp in
            if resp == .OK {
                for url in panel.urls { vm.addAttachment(url) }
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for p in providers where p.canLoadObject(ofClass: URL.self) {
            handled = true
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url = url else { return }
                DispatchQueue.main.async { vm.addAttachment(url) }
            }
        }
        return handled
    }
}
