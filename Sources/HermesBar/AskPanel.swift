import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers
import UserNotifications
import MarkdownUI

// off = Spotlight (click-away closes) · here = stays in place · everywhere = follows you
enum PinMode: String { case off, here, everywhere }

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

// MARK: - Multiline input (Enter = send, Shift+Enter = newline)

struct MultilineInput: NSViewRepresentable {
    @Binding var text: String
    var textColor: NSColor
    var onSend: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.borderType = .noBorder
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.drawsBackground = false
        tv.font = .systemFont(ofSize: 16)
        tv.textColor = textColor
        tv.insertionPointColor = textColor
        tv.typingAttributes = [.foregroundColor: textColor, .font: NSFont.systemFont(ofSize: 16)]
        tv.textContainerInset = NSSize(width: 0, height: 2)
        tv.string = text
        context.coordinator.textView = tv
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tv = nsView.documentView as? NSTextView else { return }
        if tv.string != text { tv.string = text }
        tv.textColor = textColor
        tv.insertionPointColor = textColor
        tv.typingAttributes = [.foregroundColor: textColor, .font: NSFont.systemFont(ofSize: 16)]
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MultilineInput
        weak var textView: NSTextView?
        init(_ p: MultilineInput) { parent = p }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
                if shift {
                    textView.insertNewline(nil)
                } else {
                    parent.onSend()
                }
                return true
            }
            return false
        }
    }
}

// MARK: - Attachments

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

// MARK: - Frosted-glass background

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

// MARK: - Resizable borderless floating panel

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
        minSize = NSSize(width: 460, height: 260)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - View model

final class AskViewModel: ObservableObject {
    @Published var input: String = ""
    @Published var response: String = ""
    @Published var errorText: String = ""
    @Published var isLoading: Bool = false
    @Published var elapsed: TimeInterval = 0
    @Published var pinMode: PinMode = PinMode(rawValue: UserDefaults.standard.string(forKey: "hb.pinmode") ?? "off") ?? .off
    @Published var notifyWhenDone: Bool = UserDefaults.standard.bool(forKey: "hb.notify")
    @Published var attachments: [AttachmentItem] = []
    @Published var mode: String = UserDefaults.standard.string(forKey: "hb.mode") ?? "fast"
    @Published var withScreenshot: Bool =
        (UserDefaults.standard.object(forKey: "hb.withshot") as? Bool) ?? true

    @Published var theme: Theme = Settings.shared.theme
    @Published var isArabic: Bool = Settings.shared.language == .arabic

    var onClose: (() -> Void)?

    private var currentTask: Task<Void, Never>?
    private var timerCancellable: AnyCancellable?
    private var startDate: Date?
    private var lastText = ""
    private var lastImages: [String] = []
    private var lastHost = ""
    private var lastDetail = "high"
    private var lastEffort = "low"

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
        let next: PinMode = (pinMode == .off) ? .here : (pinMode == .here ? .everywhere : .off)
        pinMode = next
        UserDefaults.standard.set(next.rawValue, forKey: "hb.pinmode")
    }

    func toggleNotify() {
        notifyWhenDone.toggle()
        UserDefaults.standard.set(notifyWhenDone, forKey: "hb.notify")
    }

    func applySpiderPrefix() {
        let prefix = isArabic
            ? "استخدم Scrapling لقراءة/فحص هذا الرابط بسرعة: "
            : "Use Scrapling to quickly read/scrape this URL: "
        if !input.hasPrefix(prefix) { input = prefix + input }
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
        stop()
        input = ""
        response = ""
        errorText = ""
        isLoading = false
        elapsed = 0
        attachments = []
        refreshFromSettings()
    }

    func send() {
        let q0 = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!q0.isEmpty || !attachments.isEmpty), !isLoading else { return }
        isLoading = true
        errorText = ""
        response = ""
        startTimer()

        let atts = attachments
        attachments = []
        let wantsShot = withScreenshot
        let ar = isArabic
        let fast = (mode == "fast")
        let effort = fast ? "low" : "high"
        let detail = "high"
        let host = fast ? fastHost() : Settings.shared.host

        DispatchQueue.global(qos: .userInitiated).async {
            var images: [String] = []
            if wantsShot, let shot = Screenshot.captureBase64PNG(maxPx: 0) {
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
            DispatchQueue.main.async {
                self.lastText = text; self.lastImages = images
                self.lastHost = host; self.lastDetail = detail; self.lastEffort = effort
                self.launch()
            }
        }
    }

    func regenerate() {
        guard !isLoading, !lastText.isEmpty else { return }
        isLoading = true
        errorText = ""
        response = ""
        startTimer()
        launch()
    }

    private func launch() {
        currentTask = HermesClient.shared.askStream(
            host: lastHost,
            question: lastText,
            imageDataURLs: lastImages,
            imageDetail: lastDetail,
            reasoningEffort: lastEffort,
            onDelta: { [weak self] (piece: String) in
                self?.response += piece
            },
            onDone: { [weak self] (err: Error?) in
                self?.finish(err)
            }
        )
    }

    private func finish(_ err: Error?) {
        isLoading = false
        stopTimer()
        if let err = err, response.isEmpty {
            errorText = err.localizedDescription
        }
        if notifyWhenDone {
            let summary = errorText.isEmpty ? String(response.prefix(120)) : errorText
            Notifier.notify(
                title: isArabic ? "هيرميس خلّص ✅" : "Hermes finished ✅",
                body: summary.isEmpty ? (isArabic ? "تمّت المهمة" : "Task done") : summary
            )
        }
    }

    func stop() {
        currentTask?.cancel()
        currentTask = nil
        isLoading = false
        stopTimer()
    }

    private func startTimer() {
        startDate = Date()
        elapsed = 0
        timerCancellable = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in
                guard let self = self, let s = self.startDate else { return }
                self.elapsed = Date().timeIntervalSince(s)
            }
    }

    private func stopTimer() {
        timerCancellable?.cancel()
        timerCancellable = nil
        if let s = startDate { elapsed = Date().timeIntervalSince(s) }
    }
}

// MARK: - Panel controller

final class AskPanelController: NSObject, NSWindowDelegate {
    private var panel: FloatingPanel?
    private let viewModel = AskViewModel()
    private var cancellables = Set<AnyCancellable>()
    private let defaultSize = NSSize(width: 720, height: 500)

    var isVisible: Bool { panel?.isVisible ?? false }

    func setScreenshot(_ on: Bool) { viewModel.setWithScreenshot(on) }

    private func savedSize() -> NSSize {
        let d = UserDefaults.standard
        let w = d.double(forKey: "hb.win.w")
        let h = d.double(forKey: "hb.win.h")
        if w >= 460, h >= 260 { return NSSize(width: w, height: h) }
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
        if cancellables.isEmpty {
            viewModel.$pinMode
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.applyPinBehavior() }
                .store(in: &cancellables)
        }
    }

    private func applyPinBehavior() {
        guard let panel = panel else { return }
        switch viewModel.pinMode {
        case .off, .everywhere:
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        case .here:
            panel.collectionBehavior = [.fullScreenAuxiliary]
        }
    }

    func present() {
        viewModel.reset()
        viewModel.onClose = { [weak self] in self?.dismiss() }
        ensurePanel()
        applyPinBehavior()
        position(panel!)
        NSApp.activate(ignoringOtherApps: true)
        panel!.makeKeyAndOrderFront(nil)
    }

    func presentShowingResult() {
        viewModel.onClose = { [weak self] in self?.dismiss() }
        ensurePanel()
        applyPinBehavior()
        position(panel!)
        NSApp.activate(ignoringOtherApps: true)
        panel!.makeKeyAndOrderFront(nil)
    }

    func dismiss() { panel?.orderOut(nil) }

    func applyTheme() { viewModel.refreshFromSettings() }

    func windowDidResignKey(_ notification: Notification) {
        if viewModel.pinMode == .off {
            DispatchQueue.main.async { [weak self] in self?.dismiss() }
        }
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

// MARK: - SwiftUI content

struct AskView: View {
    @ObservedObject var vm: AskViewModel
    @State private var dropTargeted = false

    private var t: Theme { vm.theme }
    private var ar: Bool { vm.isArabic }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            inputField
            controlRow
            if !vm.attachments.isEmpty { attachmentsRow }
            Divider().opacity(0.15)
            contentArea
            modeBar
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(background)
        .overlay(dropHighlight)
        .environment(\.layoutDirection, ar ? .rightToLeft : .leftToRight)
        .onExitCommand { vm.onClose?() }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
        }
    }

    @ViewBuilder private var background: some View {
        if t.isGlass {
            VisualEffectBackground()
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        } else {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(t.background)
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(t.accent.opacity(0.25), lineWidth: 1))
        }
    }

    @ViewBuilder private var dropHighlight: some View {
        if dropTargeted {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(t.accent, lineWidth: 2)
        }
    }

    private var placeholder: String {
        ar ? "وش تحتاج مساعدة فيه؟ (Shift+Enter لسطر جديد)" : "What do you need help with?"
    }

    private var inputField: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundColor(t.accent)
                .font(.system(size: 16, weight: .semibold))
                .padding(.top, 3)
            ZStack(alignment: .topLeading) {
                if vm.input.isEmpty {
                    Text(placeholder)
                        .foregroundColor(t.textSecondary)
                        .font(.system(size: 16))
                        .padding(.top, 2)
                        .allowsHitTesting(false)
                }
                MultilineInput(text: $vm.input, textColor: NSColor(t.textPrimary), onSend: { vm.send() })
                    .frame(minHeight: 22, maxHeight: 100)
            }
        }
    }

    private var controlRow: some View {
        HStack(spacing: 14) {
            iconButton("paperclip", active: false, help: ar ? "إرفاق ملف أو صورة" : "Attach file or image") { openFilePicker() }
            iconButton("doc.text.magnifyingglass", active: false, help: ar ? "قراءة/فحص سريع للصفحة (Scrapling)" : "Quick read/scrape (Scrapling)") { vm.applySpiderPrefix() }
            iconButton(vm.withScreenshot ? "eye.fill" : "eye.slash", active: vm.withScreenshot, help: ar ? "رؤية الشاشة" : "See screen") { vm.setWithScreenshot(!vm.withScreenshot) }
            iconButton(pinIcon, active: vm.pinMode != .off, help: pinHelp) { vm.cyclePinMode() }
            iconButton(vm.notifyWhenDone ? "bell.fill" : "bell.slash", active: vm.notifyWhenDone, help: ar ? "أشعرني لما يخلّص" : "Notify when done") { vm.toggleNotify() }
            iconButton("macwindow.on.rectangle", active: false, help: ar ? "افتح هيرميس ديسكتوب" : "Open Hermes Desktop") { openHermesDesktop() }

            Spacer()

            if vm.isLoading {
                Button(action: { vm.stop() }) {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
                .help(ar ? "إيقاف" : "Stop")
            } else {
                Button(action: { vm.send() }) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(canSend ? t.accent : t.textSecondary.opacity(0.4))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
        }
    }

    private func iconButton(_ name: String, active: Bool, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 15))
                .foregroundColor(active ? t.accent : t.textSecondary)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var canSend: Bool {
        !vm.input.trimmingCharacters(in: .whitespaces).isEmpty || !vm.attachments.isEmpty
    }

    private var attachmentsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(vm.attachments) { att in
                    HStack(spacing: 5) {
                        Image(systemName: att.symbol).font(.system(size: 11)).foregroundColor(t.accent)
                        Text(att.name).font(.system(size: 12)).foregroundColor(t.textPrimary).lineLimit(1)
                        Button(action: { vm.removeAttachment(att) }) {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundColor(t.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
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
                        Text((ar ? "هيرميس يشتغل… " : "Working… ") + timerText)
                            .font(.system(size: 13))
                            .foregroundColor(t.textSecondary)
                    }
                }
                if !vm.errorText.isEmpty {
                    Text(vm.errorText).font(.system(size: 14)).foregroundColor(.red).textSelection(.enabled)
                }
                if !vm.response.isEmpty {
                    Markdown(vm.response)
                        .markdownTextStyle { ForegroundColor(t.textPrimary); FontSize(16) }
                        .markdownBlockStyle(\.codeBlock) { configuration in
                            codeBlock(configuration)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !vm.isLoading { answerActions }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var answerActions: some View {
        HStack(spacing: 14) {
            actionButton("doc.on.doc", ar ? "نسخ الكل" : "Copy all") { copyToPasteboard(vm.response) }
            if vm.response.contains("```") {
                actionButton("curlybraces", ar ? "نسخ الكود" : "Copy code") { copyToPasteboard(extractCode(vm.response)) }
            }
            actionButton("arrow.clockwise", ar ? "إعادة توليد" : "Regenerate") { vm.regenerate() }
            Spacer()
            Text(timerText).font(.system(size: 11)).foregroundColor(t.textSecondary.opacity(0.8))
        }
        .padding(.top, 4)
    }

    private func actionButton(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 12))
                Text(label).font(.system(size: 11))
            }
            .foregroundColor(t.textSecondary)
        }
        .buttonStyle(.plain)
    }

    private var modeBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.fill").font(.system(size: 12)).foregroundColor(t.textSecondary)
            ForEach(["fast", "quality"], id: \.self) { m in
                let selected = vm.mode == m
                Button(action: { vm.setMode(m) }) {
                    Text(modeLabel(m))
                        .font(.system(size: 12, weight: selected ? .bold : .regular))
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .background(Capsule().fill(selected ? t.accent.opacity(0.28) : Color.clear))
                        .foregroundColor(selected ? t.textPrimary : t.textSecondary)
                }
                .buttonStyle(.plain)
            }
            Text(modeHint).font(.system(size: 10)).foregroundColor(t.textSecondary.opacity(0.7)).lineLimit(1)
            Spacer()
        }
    }

    private var timerText: String {
        String(format: "⏱ %.1f%@", vm.elapsed, ar ? " ث" : "s")
    }

    private var pinIcon: String {
        switch vm.pinMode {
        case .off: return "pin"
        case .here: return "pin.fill"
        case .everywhere: return "pin.circle.fill"
        }
    }

    private var pinHelp: String {
        switch vm.pinMode {
        case .off: return ar ? "غير مثبّت (يختفي بالضغط برّه) — اضغط: ثبّت هنا" : "Off (Spotlight) — click: pin here"
        case .here: return ar ? "مثبّت هنا (يبقى بمكانه) — اضغط: كل مكان" : "Pinned here — click: everywhere"
        case .everywhere: return ar ? "معك في كل مكان — اضغط: إلغاء" : "Everywhere — click: off"
        }
    }

    private func modeLabel(_ m: String) -> String {
        if m == "fast" { return ar ? "سريع" : "Fast" }
        return ar ? "جودة" : "Quality"
    }

    private var modeHint: String {
        vm.mode == "fast" ? (ar ? "أسرع · تفكير أقل" : "faster") : (ar ? "أعمق · تفكير أعلى" : "deeper")
    }

    // MARK: - Helpers

    private func copyToPasteboard(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    // Styled code block with a per-block copy button (kept left-to-right).
    private func codeBlock(_ configuration: CodeBlockConfiguration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text((configuration.language?.isEmpty == false ? configuration.language! : "code"))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(t.textSecondary)
                Spacer()
                Button(action: { copyToPasteboard(configuration.content) }) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundColor(t.textSecondary)
                }
                .buttonStyle(.plain)
                .help(ar ? "نسخ الكود" : "Copy code")
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)

            ScrollView(.horizontal, showsIndicators: false) {
                configuration.label
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(13)
                        ForegroundColor(t.textPrimary)
                    }
                    .padding(10)
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(t.surface))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(t.textSecondary.opacity(0.15)))
        .padding(.vertical, 4)
    }

    private func extractCode(_ md: String) -> String {
        let parts = md.components(separatedBy: "```")
        var blocks: [String] = []
        var i = 1
        while i < parts.count {
            var block = parts[i]
            if let nl = block.firstIndex(of: "\n") {
                block = String(block[block.index(after: nl)...])
            }
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { blocks.append(trimmed) }
            i += 2
        }
        return blocks.joined(separator: "\n\n")
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
