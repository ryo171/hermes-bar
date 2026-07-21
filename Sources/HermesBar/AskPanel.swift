import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers
import UserNotifications
import MarkdownUI

enum PinMode: String { case off, here, everywhere }

enum PanelLayout: String, CaseIterable {
    case classic, chat, rail, minimal, aurora, commandDeck, palette, aiChat
    var label: String {
        switch self {
        case .classic: return "Classic"
        case .chat:    return "Chat"
        case .rail:    return "Rail"
        case .minimal: return "Minimal"
        case .aurora:  return "Aurora Canvas"
        case .commandDeck: return "Command Deck"
        case .palette: return "Command Palette"
        case .aiChat:  return "AI Chat"
        }
    }
}

extension Notification.Name {
    static let hbSpawnWindow   = Notification.Name("hb.spawnWindow")
    static let hbPendingResult = Notification.Name("hb.pendingResult")
}

// How the "Hermes is thinking" state is visualised — user-selectable in Settings.
enum ThinkingStyle: String, CaseIterable {
    case topWash        // morphing colour wash across the top (default)
    case radialAurora   // circular drifting colour blobs
    case pulseDots      // three pulsing dots
    case statusLine     // Swiggy-style cycling status text
    case off            // plain spinner only

    var labelAr: String {
        switch self {
        case .topWash: return "وش علوي متدرّج"
        case .radialAurora: return "شفق دائري"
        case .pulseDots: return "نقاط نابضة"
        case .statusLine: return "حالة متغيّرة"
        case .off: return "بدون"
        }
    }
    var labelEn: String {
        switch self {
        case .topWash: return "Top wash"
        case .radialAurora: return "Radial aurora"
        case .pulseDots: return "Pulse dots"
        case .statusLine: return "Status line"
        case .off: return "Off"
        }
    }
}

// MARK: - Control-icon catalog (shared by the panel and the Settings manager)

// A stable id + label for every icon in the control row, so the Settings
// "icon manager" can hide/show them non-destructively (nothing is ever deleted).
struct PanelIcon: Identifiable {
    let id: String
    let symbol: String
    let labelAr: String
    let labelEn: String
    func title(_ ar: Bool) -> String { ar ? labelAr : labelEn }

    // Order matters — this is the display order in the row and the manager.
    static let all: [PanelIcon] = [
        PanelIcon(id: "newchat", symbol: "square.and.pencil", labelAr: "محادثة جديدة", labelEn: "New chat"),
        PanelIcon(id: "mode",    symbol: "brain",             labelAr: "توفير/عميق",  labelEn: "Saving/Deep"),
        PanelIcon(id: "web",     symbol: "globe",             labelAr: "بحث ويب",      labelEn: "Web search"),
        PanelIcon(id: "attach",  symbol: "paperclip",         labelAr: "إرفاق",        labelEn: "Attach"),
        PanelIcon(id: "scrape",  symbol: "doc.text.magnifyingglass", labelAr: "قراءة سريعة", labelEn: "Quick read"),
        PanelIcon(id: "screen",  symbol: "eye",               labelAr: "رؤية الشاشة",  labelEn: "See screen"),
        PanelIcon(id: "pin",     symbol: "pin",               labelAr: "تثبيت",        labelEn: "Pin"),
        PanelIcon(id: "notify",  symbol: "bell",              labelAr: "إشعار",        labelEn: "Notify"),
        PanelIcon(id: "spawn",   symbol: "plus.rectangle.on.rectangle", labelAr: "نافذة جديدة", labelEn: "New window"),
        PanelIcon(id: "desktop", symbol: "macwindow.on.rectangle", labelAr: "هيرميس ديسكتوب", labelEn: "Hermes Desktop"),
        PanelIcon(id: "tasks",   symbol: "checklist", labelAr: "مهمة (Kanban)", labelEn: "Task (Kanban)"),
        PanelIcon(id: "schedule", symbol: "calendar.badge.clock", labelAr: "جدولة", labelEn: "Schedule"),
        PanelIcon(id: "server",  symbol: "link", labelAr: "محلي/سيرفر", labelEn: "Local/Server"),
    ]
}

// MARK: - Reusable interaction / motion

// Spring-bounce + pop on press (adapted from the "X like" reference): the control
// scales down when pressed and springs back with a lively overshoot on release.
struct SpringPopButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.82
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1.0)
            .animation(.spring(response: 0.30, dampingFraction: 0.42), value: configuration.isPressed)
    }
}

// Copy button for code-block rectangles with a springy ✓ confirmation, matching
// the message-copy feedback: icon pops into a green checkmark, then settles back.
struct CodeCopyButton: View {
    let code: String
    let idleColor: Color
    let helpCopy: String
    let helpDone: String
    @State private var copied = false

    var body: some View {
        Button {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(code, forType: .string)
            withAnimation(.spring(response: 0.28, dampingFraction: 0.45)) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                withAnimation(.easeOut(duration: 0.25)) { copied = false }
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: copied ? .bold : .regular))
                .foregroundColor(copied ? .green : idleColor)
                .scaleEffect(copied ? 1.2 : 1.0)
        }
        .buttonStyle(.plain)
        .help(copied ? helpDone : helpCopy)
    }
}

// "Hermes is thinking" cue (adapted from the Gemini response-gradient reference):
// a soft, morphing multi-colour wash concentrated in the TOP of the panel behind
// the content — NOT on the window edges. It drifts + hue-rotates while loading and
// fades down the panel via a mask, so only the upper area is tinted.
struct ThinkingWash: View {
    var speed: Double = 1.0
    var intensity: Double = 0.6
    private let colors: [Color] = [
        Color(red: 0.42, green: 0.55, blue: 1.00),   // blue
        Color(red: 0.30, green: 0.85, blue: 0.80),   // teal
        Color(red: 0.45, green: 0.90, blue: 0.45),   // green
        Color(red: 0.98, green: 0.80, blue: 0.35),   // amber
        Color(red: 0.98, green: 0.55, blue: 0.45),   // coral
        Color(red: 0.85, green: 0.50, blue: 0.95),   // violet
    ]
    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate * speed
            LinearGradient(gradient: Gradient(colors: colors),
                           startPoint: UnitPoint(x: 0.5 + 0.5 * cos(t * 0.55), y: 0.0),
                           endPoint: UnitPoint(x: 0.5 + 0.5 * sin(t * 0.42), y: 1.0))
                .hueRotation(.degrees(t * 26))
                .opacity(intensity)
                .blur(radius: 42)
                .mask(
                    LinearGradient(colors: [.white, .white.opacity(0.28), .clear],
                                   startPoint: .top, endPoint: .bottom)
                )
        }
        .allowsHitTesting(false)
    }
}

// Circular drifting colour blobs behind the top of the panel (alternative to the
// top wash) — a soft "aurora" that morphs while thinking.
struct RadialAurora: View {
    var speed: Double = 1.0
    var intensity: Double = 0.5
    private let colors: [Color] = [
        Color(red: 0.42, green: 0.55, blue: 1.00),
        Color(red: 0.30, green: 0.85, blue: 0.80),
        Color(red: 0.98, green: 0.55, blue: 0.45),
        Color(red: 0.85, green: 0.50, blue: 0.95),
    ]
    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate * speed
            ZStack {
                ForEach(0..<colors.count, id: \.self) { i in
                    Circle()
                        .fill(colors[i])
                        .frame(width: 220, height: 220)
                        .offset(x: CGFloat(cos(t * 0.5 + Double(i) * 1.7)) * 90,
                                y: CGFloat(sin(t * 0.42 + Double(i) * 1.3)) * 60)
                        .blur(radius: 65)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .opacity(intensity)
            .mask(LinearGradient(colors: [.white, .white.opacity(0.5), .white.opacity(0.15)], startPoint: .top, endPoint: .bottom))
        }
        .allowsHitTesting(false)
    }
}

// Three pulsing dots.
struct PulseDots: View {
    var tint: Color
    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    let p = abs(sin(t * 3.0 + Double(i) * 0.6))
                    Circle().fill(tint)
                        .frame(width: 7, height: 7)
                        .scaleEffect(0.6 + 0.4 * p)
                        .opacity(0.45 + 0.55 * p)
                }
            }
        }
    }
}

// Swiggy-style cycling status: each phrase slides up + fades as the next arrives.
struct StatusCycler: View {
    let phrases: [String]
    var tint: Color
    @State private var idx = 0
    private let timer = Timer.publish(every: 1.6, on: .main, in: .common).autoconnect()
    var body: some View {
        Text(phrases.isEmpty ? "" : phrases[idx % phrases.count])
            .font(.system(size: 13)).foregroundColor(tint)
            .id(idx)
            .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                    removal: .move(edge: .top).combined(with: .opacity)))
            .onReceive(timer) { _ in withAnimation(.easeInOut(duration: 0.35)) { idx += 1 } }
            .clipped()
    }
}

// A read-only NSTextView that sizes itself to its content — gives real, native,
// drag-anywhere text selection (SwiftUI's Markdown splits an answer into many
// blocks, which prevents selecting across them). Used for the "select text" mode.
final class SelfSizingTextView: NSTextView {
    override var intrinsicContentSize: NSSize {
        guard let lm = layoutManager, let tc = textContainer else { return super.intrinsicContentSize }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc)
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(used.height))
    }
}

struct SelectableText: NSViewRepresentable {
    let text: String
    var color: NSColor
    var fontSize: CGFloat = 15

    func makeNSView(context: Context) -> SelfSizingTextView {
        let tv = SelfSizingTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        return tv
    }

    func updateNSView(_ tv: SelfSizingTextView, context: Context) {
        if tv.string != text { tv.string = text }
        tv.font = .systemFont(ofSize: fontSize)
        tv.textColor = color
        tv.invalidateIntrinsicContentSize()
    }

    // Give SwiftUI a correct height for the proposed width (macOS 13+).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SelfSizingTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 400
        nsView.string = text
        nsView.font = .systemFont(ofSize: fontSize)
        guard let tc = nsView.textContainer, let lm = nsView.layoutManager else { return nil }
        tc.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        let h = lm.usedRect(for: tc).height
        return CGSize(width: width, height: ceil(h))
    }
}

// Renders Markdown as a natively-selectable NSTextView with real bold/italic (no
// literal "*" or "#"), so any part is drag-selectable and copies out clean text.
struct SelectableAttributedText: NSViewRepresentable {
    let markdown: String
    var color: NSColor
    var rtl: Bool = false
    var fontSize: CGFloat = 15

    func makeNSView(context: Context) -> SelfSizingTextView {
        let tv = SelfSizingTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.alignment = rtl ? .right : .left
        tv.baseWritingDirection = rtl ? .rightToLeft : .leftToRight
        return tv
    }

    func updateNSView(_ tv: SelfSizingTextView, context: Context) {
        tv.textStorage?.setAttributedString(Self.build(markdown, color: color, fontSize: fontSize, rtl: rtl))
        tv.alignment = rtl ? .right : .left
        tv.baseWritingDirection = rtl ? .rightToLeft : .leftToRight
        tv.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SelfSizingTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 400
        nsView.textStorage?.setAttributedString(Self.build(markdown, color: color, fontSize: fontSize, rtl: rtl))
        guard let tc = nsView.textContainer, let lm = nsView.layoutManager else { return nil }
        tc.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        let h = lm.usedRect(for: tc).height
        return CGSize(width: width, height: ceil(h))
    }

    // Memoize parsed results — sizeThatFits/updateNSView can run many times per layout
    // pass, and re-parsing Markdown each call thrashed the CPU (froze the app).
    private static var cache: [String: NSAttributedString] = [:]

    static func build(_ md: String, color: NSColor, fontSize: CGFloat, rtl: Bool) -> NSAttributedString {
        let key = "\(rtl ? 1 : 0)|\(Int(fontSize))|\(color.hashValue)|\(md)"
        if let hit = cache[key] { return hit }
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full,
                                                           failurePolicy: .returnPartiallyParsedIfPossible)
        let ns: NSMutableAttributedString
        if let parsed = try? NSAttributedString(markdown: md, options: opts, baseURL: nil) {
            ns = NSMutableAttributedString(attributedString: parsed)
        } else {
            ns = NSMutableAttributedString(string: md)
        }
        let full = NSRange(location: 0, length: ns.length)
        // Resize every run to `fontSize` while preserving bold/italic/mono traits.
        ns.enumerateAttribute(.font, in: full, options: []) { value, range, _ in
            let base = (value as? NSFont) ?? NSFont.systemFont(ofSize: fontSize)
            let traits = base.fontDescriptor.symbolicTraits
            let desc = NSFont.systemFont(ofSize: fontSize).fontDescriptor.withSymbolicTraits(traits)
            let f = NSFont(descriptor: desc, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
            ns.addAttribute(.font, value: f, range: range)
        }
        ns.addAttribute(.foregroundColor, value: color, range: full)
        // Right-align + RTL base direction for Arabic so text hugs the right edge.
        let para = NSMutableParagraphStyle()
        para.alignment = rtl ? .right : .left
        para.baseWritingDirection = rtl ? .rightToLeft : .leftToRight
        ns.addAttribute(.paragraphStyle, value: para, range: full)
        if cache.count > 240 { cache.removeAll() }
        cache[key] = ns
        return ns
    }

    // Plain text of the markdown (no syntax) — used for the "copy all" button.
    static func plain(_ md: String) -> String {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full,
                                                           failurePolicy: .returnPartiallyParsedIfPossible)
        if let a = try? AttributedString(markdown: md, options: opts) { return String(a.characters) }
        return md
    }
}

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

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let role: String   // "user" or "assistant"
    var text: String
    var elapsed: TimeInterval = 0   // time this answer took (assistant messages)
}

// MARK: - Local Kanban (real cards, persisted; not dependent on Hermes' API)

struct KanbanCard: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var done: Bool = false
}

final class KanbanStore: ObservableObject {
    static let shared = KanbanStore()
    @Published var cards: [KanbanCard] = [] { didSet { save() } }
    private let key = "hb.kanban.cards"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let c = try? JSONDecoder().decode([KanbanCard].self, from: data) { cards = c }
    }
    private func save() {
        if let d = try? JSONEncoder().encode(cards) { UserDefaults.standard.set(d, forKey: key) }
    }
    func add(_ title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        cards.append(KanbanCard(title: t))
    }
    func toggle(_ card: KanbanCard) {
        if let i = cards.firstIndex(where: { $0.id == card.id }) { cards[i].done.toggle() }
    }
    func remove(_ card: KanbanCard) { cards.removeAll { $0.id == card.id } }
    func moveUp(_ card: KanbanCard) {
        guard let i = cards.firstIndex(where: { $0.id == card.id }), i > 0 else { return }
        cards.swapAt(i, i - 1)
    }
    func moveDown(_ card: KanbanCard) {
        guard let i = cards.firstIndex(where: { $0.id == card.id }), i < cards.count - 1 else { return }
        cards.swapAt(i, i + 1)
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
                    parent.onSend()   // send() clears the bound text → the field empties
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
        isReleasedWhenClosed = false   // ARC owns the panel; close() must not release it
        minSize = NSSize(width: 460, height: 260)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - View model

final class AskViewModel: ObservableObject {
    @Published var input: String = ""
    @Published var messages: [ChatMessage] = []
    @Published var errorText: String = ""
    @Published var isLoading: Bool = false
    @Published var queued: String?   // text typed while a turn is running; auto-sent on finish
    @Published var suggestions: [String] = []   // AI-generated follow-up questions (AI Chat layout)
    @Published var streamingMessageId: UUID?   // the message currently being streamed (rendered as plain text)
    @Published var elapsed: TimeInterval = 0
    @Published var pinMode: PinMode = PinMode(rawValue: UserDefaults.standard.string(forKey: "hb.pinmode") ?? "off") ?? .off
    @Published var notifyWhenDone: Bool = UserDefaults.standard.bool(forKey: "hb.notify")
    @Published var attachments: [AttachmentItem] = []
    @Published var mode: String = UserDefaults.standard.string(forKey: "hb.mode") ?? "fast"
    // Saving = talk directly to a cheap model (no Hermes agent). Deep = full agent.
    @Published var savingMode: Bool = UserDefaults.standard.bool(forKey: "hb.saving")
    // Web search in Saving mode (OpenRouter web plugin) — off by default (costs per search).
    @Published var webSearch: Bool = UserDefaults.standard.bool(forKey: "hb.websearch")
    @Published var withScreenshot: Bool =
        (UserDefaults.standard.object(forKey: "hb.withshot") as? Bool) ?? true

    @Published var theme: Theme = Settings.shared.theme
    @Published var isArabic: Bool = Settings.shared.language == .arabic
    @Published var layout: PanelLayout = PanelLayout(rawValue: Settings.shared.layoutName) ?? .classic

    // Per-message rating (1 = 👍, -1 = 👎). Tapping a thumb also queues a light
    // preference note that rides along with the NEXT turn, nudging Hermes' style.
    @Published var ratings: [UUID: Int] = [:]
    private var pendingFeedbackNote: String?

    func rate(_ id: UUID, up: Bool) {
        // Toggle off if the same thumb is tapped again.
        if ratings[id] == (up ? 1 : -1) {
            ratings[id] = nil
            pendingFeedbackNote = nil
            return
        }
        ratings[id] = up ? 1 : -1
        pendingFeedbackNote = up
            ? (isArabic ? "(ملاحظة تفضيل: ردك السابق كان ممتاز — استمر بنفس الأسلوب والمستوى.)"
                        : "(Preference note: your previous answer was great — keep this style and depth.)")
            : (isArabic ? "(ملاحظة تفضيل: ردك السابق لم يكن جيداً — حسّن الإجابة وأسلوبها في المرة الجاية.)"
                        : "(Preference note: your previous answer wasn't good — improve the answer and its style next time.)")
    }

    var onClose: (() -> Void)?
    var onTaskFinishedNotify: (() -> Void)?   // fired when a notify-worthy task completes

    // A stable id per window/conversation (Hermes session-id shape). Groundwork
    // for sharing the conversation with Hermes Desktop.
    private(set) var sessionId: String = AskViewModel.newSessionId()
    private(set) var sessionEstablished = false   // true after the first successful turn
    private var titleApplied = false              // PATCH the session title only once
    static func newSessionId() -> String {
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd_HHmmss"
        let rand = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6)).lowercased()
        return "\(df.string(from: Date()))_\(rand)"
    }

    // The session's human title (first question), shown in Hermes Desktop's list.
    var sessionTitle: String {
        let q = messages.first(where: { $0.role == "user" })?.text ?? ""
        return String(q.prefix(60)).replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    }

    // Formatted transcript used to hand the conversation off to Hermes Desktop.
    func transcriptForHandoff() -> String {
        guard messages.contains(where: { !$0.text.isEmpty }) else { return "" }
        let ar = isArabic
        var s = ar
            ? "متابعة محادثة من HermesBar (جلسة \(sessionId)):\n\n"
            : "Continuing a HermesBar conversation (session \(sessionId)):\n\n"
        for m in messages where !m.text.isEmpty {
            let who = m.role == "user" ? (ar ? "أنا" : "Me") : "Hermes"
            s += "### \(who)\n\(m.text)\n\n"
        }
        return s
    }

    private var currentTask: Task<Void, Never>?
    private var timerCancellable: AnyCancellable?
    private var pendingBuffer = ""                 // deltas awaiting a throttled flush
    private var flushCancellable: AnyCancellable?
    private var startDate: Date?
    private var lastConversation: [[String: Any]] = []
    private var hostForTurn = ""
    private var effortForTurn = "low"
    private var includeSystemForTurn = true
    private var turnHasImages = false   // → route Saving mode to the vision model
    private var noteFilename: String?

    // Server-managed sessions: Hermes holds history in state.db (keyed by the
    // session header), so we send only the new turn. Off → full history each time
    // (for non-Hermes OpenAI hosts).
    private var serverManaged: Bool { Settings.shared.serverManagedSessions }

    // MARK: settings toggles

    func setMode(_ m: String) { mode = m; UserDefaults.standard.set(m, forKey: "hb.mode") }
    func toggleWebSearch() { webSearch.toggle(); UserDefaults.standard.set(webSearch, forKey: "hb.websearch") }

    // Flip Saving ⇄ Deep. Escalating to Deep starts a FRESH Hermes session so the
    // next turn re-seeds it with the full transcript — the conversation continues
    // in Hermes/Desktop with everything, no re-explaining.
    func toggleSaving() {
        savingMode.toggle()
        UserDefaults.standard.set(savingMode, forKey: "hb.saving")
        if !savingMode {
            sessionId = AskViewModel.newSessionId()
            sessionEstablished = false
            titleApplied = false
        }
    }
    func setWithScreenshot(_ on: Bool) { withScreenshot = on; UserDefaults.standard.set(on, forKey: "hb.withshot") }
    func toggleNotify() { notifyWhenDone.toggle(); UserDefaults.standard.set(notifyWhenDone, forKey: "hb.notify") }

    func cyclePinMode() {
        let next: PinMode = (pinMode == .off) ? .here : (pinMode == .here ? .everywhere : .off)
        pinMode = next
        UserDefaults.standard.set(next.rawValue, forKey: "hb.pinmode")
    }

    private func fastHost() -> String {
        let h = UserDefaults.standard.string(forKey: "hb.fasthost") ?? ""
        return h.isEmpty ? Settings.shared.host : h
    }

    func applySpiderPrefix() {
        let prefix = isArabic
            ? "استخدم Scrapling لقراءة/فحص هذا الرابط بسرعة: "
            : "Use Scrapling to quickly read/scrape this URL: "
        if !input.hasPrefix(prefix) { input = prefix + input }
    }

    // Prime a Kanban task-creation prompt (Hermes manages the board via its tools).
    func applyTaskPrefix() {
        let prefix = isArabic ? "أضِف مهمة إلى لوحة Kanban في هيرميس: " : "Add a task to my Hermes Kanban board: "
        if !input.hasPrefix(prefix) { input = prefix + input }
    }

    // Prime a scheduling (cron) prompt.
    func applySchedulePrefix() {
        let prefix = isArabic ? "جدوِل هذه المهمة (cron) في هيرميس: " : "Schedule this task (cron) in Hermes: "
        if !input.hasPrefix(prefix) { input = prefix + input }
    }

    // Generate 3 short follow-up questions for the AI Chat layout — one cheap call to
    // the Saving model so it stays fast + low-cost regardless of the current mode.
    func fetchSuggestions() {
        guard Settings.shared.showSuggestions else { suggestions = []; return }
        let answer = lastAssistantText
        guard answer.count > 40 else { suggestions = []; return }
        let s = Settings.shared
        let ar = isArabic
        let prompt = "الإجابة:\n" + String(answer.prefix(1400))
            + "\n\nاقترح ٣ أسئلة متابعة قصيرة جداً **بالعربية فقط**، سطر لكل سؤال، بدون ترقيم، بدون مقدمات، وبدون أي وسوم تفكير مثل <think>."
        var acc = ""
        _ = HermesClient.shared.askStream(
            host: s.directHost,
            conversation: [["role": "user", "content": prompt]],
            reasoningEffort: nil,
            sessionId: nil,
            includeSystem: false,
            apiKey: s.resolvedDirectKey(),
            model: s.savingModel,
            webSearch: false,
            onDelta: { piece in acc += piece },
            onSession: { _ in },
            onDone: { [weak self] _ in
                // Drop any <think>…</think> reasoning the model may leak.
                var clean = acc
                if let r = clean.range(of: "</think>") { clean = String(clean[r.upperBound...]) }
                clean = clean.replacingOccurrences(of: "<think>", with: "").replacingOccurrences(of: "</think>", with: "")
                let lines = clean.split(separator: "\n")
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " -•*\t")) }
                    .filter { $0.count > 4 && !$0.hasPrefix("<") }
                    .prefix(3)
                self?.suggestions = Array(lines)
            }
        )
    }

    func addAttachment(_ url: URL) {
        if !attachments.contains(where: { $0.url == url }) { attachments.append(AttachmentItem(url: url)) }
    }
    func removeAttachment(_ item: AttachmentItem) { attachments.removeAll { $0.id == item.id } }

    func refreshFromSettings() {
        theme = Settings.shared.theme
        isArabic = Settings.shared.language == .arabic
        layout = PanelLayout(rawValue: Settings.shared.layoutName) ?? .classic
    }

    // MARK: conversation

    func newChat() {
        archiveToObsidian()
        stop()
        messages = []
        input = ""
        errorText = ""
        elapsed = 0
        noteFilename = nil
        sessionId = AskViewModel.newSessionId()
        sessionEstablished = false
        titleApplied = false
        includeSystemForTurn = true
    }

    var lastAssistantText: String { messages.last(where: { $0.role == "assistant" })?.text ?? "" }

    func send() {
        let q0 = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!q0.isEmpty || !attachments.isEmpty) else { return }
        // Hermes is busy → queue this message instead of interrupting; it fires
        // automatically as a new turn the moment the current one finishes.
        if isLoading {
            guard !q0.isEmpty else { return }
            queued = (queued.map { $0 + "\n" } ?? "") + q0
            input = ""
            return
        }
        errorText = ""
        suggestions = []
        isLoading = true
        startTimer()

        let atts = attachments
        attachments = []
        input = ""                 // clear the field right after sending
        let wantsShot = withScreenshot
        let ar = isArabic
        let fast = (mode == "fast")
        let effort = fast ? "low" : "high"
        let detail = "high"
        let host = fast ? fastHost() : Settings.shared.deepHost()
        // HermesBar-side web search (Tavily) — makes 🌐 work with ANY provider.
        let wantsSearch = savingMode && webSearch && !Settings.shared.searchApiKey.isEmpty
        let searchKey = Settings.shared.searchApiKey
        // A queued 👍/👎 preference note rides along with this turn, then clears.
        let feedbackNote = pendingFeedbackNote
        pendingFeedbackNote = nil

        DispatchQueue.global(qos: .userInitiated).async {
            var images: [String] = []
            if wantsShot, let shot = Screenshot.captureBase64PNG(maxPx: 0) {
                images.append("data:image/png;base64,\(shot)")
            }
            var pathNotes: [String] = []
            for a in atts {
                if a.isImage, let durl = imageDataURL(for: a.url) { images.append(durl) }
                else { pathNotes.append(a.url.path) }
            }
            var text = q0
            if text.isEmpty { text = ar ? "شوف المرفقات وساعدني." : "Take a look at the attachment(s) and help me." }
            if !pathNotes.isEmpty {
                let label = ar ? "ملفات/مجلدات مرفقة (افتحها بأدواتك):" : "Attached files/folders (open with your tools):"
                text += "\n\n" + label + "\n" + pathNotes.map { "- \($0)" }.joined(separator: "\n")
            }
            if wantsSearch, let results = HermesClient.shared.webSearchBlocking(query: q0, apiKey: searchKey) {
                text = results + "\n\n" + text
            }
            if let note = feedbackNote { text = note + "\n\n" + text }
            DispatchQueue.main.async {
                self.hostForTurn = host
                self.effortForTurn = effort
                self.startTurn(text: text, images: images, detail: detail)
            }
        }
    }

    // The OpenAI message dict for a user turn (text or multimodal text+images).
    private func userMessage(text: String, images: [String], detail: String) -> [String: Any] {
        if images.isEmpty { return ["role": "user", "content": text] }
        var content: [[String: Any]] = [["type": "text", "text": text]]
        for durl in images {
            content.append(["type": "image_url", "image_url": ["url": durl, "detail": detail]])
        }
        return ["role": "user", "content": content]
    }

    // Append a user turn and stream the reply. In server-managed mode (after the
    // first successful turn) we send ONLY this turn — Hermes has the rest.
    private func startTurn(text: String, images: [String], detail: String) {
        messages.append(ChatMessage(role: "user", text: text))
        turnHasImages = !images.isEmpty
        // Saving mode is stateless (direct provider) → always send full history.
        let serverMode = !savingMode && serverManaged && sessionEstablished
        var convo: [[String: Any]] = []
        if serverMode {
            convo = [userMessage(text: text, images: images, detail: detail)]
        } else {
            for (i, m) in messages.enumerated() {
                if i == messages.count - 1, !images.isEmpty {
                    convo.append(userMessage(text: m.text, images: images, detail: detail))
                } else {
                    convo.append(["role": m.role, "content": m.text])
                }
            }
        }
        includeSystemForTurn = !serverMode
        lastConversation = convo
        messages.append(ChatMessage(role: "assistant", text: ""))
        startStream()
    }

    // Ask the same question again. Hermes keeps history server-side and exposes no
    // public retry/undo on chat/completions, so "Regenerate" is a fresh re-ask of
    // the prompting question under the same session (new turn).
    func regenerate(_ id: UUID) {
        guard !isLoading,
              let idx = messages.firstIndex(where: { $0.id == id }),
              messages[idx].role == "assistant" else { return }
        var q = ""
        var i = idx - 1
        while i >= 0 { if messages[i].role == "user" { q = messages[i].text; break }; i -= 1 }
        guard !q.isEmpty else { return }
        errorText = ""
        isLoading = true
        startTimer()
        hostForTurn = (mode == "fast") ? fastHost() : Settings.shared.host
        effortForTurn = (mode == "fast") ? "low" : "high"
        startTurn(text: q, images: [], detail: "high")
    }

    // Condense the last answer — a new turn asking Hermes to summarize it.
    func summarize(_ id: UUID) {
        guard !isLoading,
              let idx = messages.firstIndex(where: { $0.id == id }),
              messages[idx].role == "assistant", !messages[idx].text.isEmpty else { return }
        let ar = isArabic
        errorText = ""
        isLoading = true
        startTimer()
        hostForTurn = fastHost()
        effortForTurn = "low"
        let prompt = ar
            ? "لخّص إجابتك السابقة باختصار شديد — النقاط الأساسية فقط، بدون مقدمات."
            : "Summarize your previous answer very concisely — key points only, no preamble."
        startTurn(text: prompt, images: [], detail: "high")
    }

    private func startStream() {
        guard let assistantId = messages.last(where: { $0.role == "assistant" })?.id else { return }
        // While streaming, the message is rendered as cheap plain text and tokens
        // are coalesced on a ~90ms timer — re-parsing full Markdown on every token
        // is what makes long answers choke the UI. We format once, at the end.
        streamingMessageId = assistantId
        pendingBuffer = ""
        flushCancellable = Timer.publish(every: 0.09, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.flushPending() }

        // Routing is TWO independent axes:
        //   • Destination (Local ↔ Server) — decided ONLY by the link toggle.
        //   • Mode (Saving 🍃 ↔ Deep 🧠) — decides model + thinking depth only.
        // Saving keeps the same philosophy everywhere: stateless, no session,
        // no heavy agent context — cheap quick answers.
        let s = Settings.shared
        let onServer = s.useServer && !s.serverHost.isEmpty
        // Saving: use the vision model when the turn has an image, else the fast text model.
        let savingM = (turnHasImages && !s.savingVisionModel.isEmpty) ? s.savingVisionModel : s.savingModel
        let host: String
        let model: String
        let key: String?
        if onServer {
            host = s.serverHost
            model = savingMode
                ? (s.serverSavingModel.isEmpty ? "hermes-agent" : s.serverSavingModel)
                : (s.serverDeepModel.isEmpty ? "hermes-agent" : s.serverDeepModel)
            key = s.serverKey
        } else {
            host = savingMode ? s.directHost : hostForTurn
            model = savingMode ? savingM : (s.deepModel.isEmpty ? "hermes-agent" : s.deepModel)
            key = savingMode ? s.resolvedDirectKey() : nil
        }
        let sid: String? = (!savingMode && serverManaged) ? sessionId : nil
        // Web plugin is an OpenRouter feature; used only when there's no Tavily key
        // (with a Tavily key we already injected results above, for any provider).
        let useWebSearch = savingMode && webSearch && s.searchApiKey.isEmpty && host.lowercased().contains("openrouter")

        currentTask = HermesClient.shared.askStream(
            host: host,
            conversation: lastConversation,
            reasoningEffort: savingMode ? nil : effortForTurn,
            sessionId: sid,
            includeSystem: includeSystemForTurn,
            apiKey: key,
            model: model,
            webSearch: useWebSearch,
            onDelta: { [weak self] (piece: String) in
                self?.pendingBuffer += piece
            },
            onSession: { [weak self] (sid: String) in
                self?.sessionId = sid   // adopt the server's canonical id (e.g. compression lineage)
            },
            onDone: { [weak self] (err: Error?) in
                self?.finish(err, assistantId: assistantId)
            }
        )
    }

    private func flushPending() {
        guard !pendingBuffer.isEmpty,
              let id = streamingMessageId,
              let i = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[i].text += pendingBuffer
        pendingBuffer = ""
    }

    private func endStreaming() {
        flushPending()
        flushCancellable?.cancel()
        flushCancellable = nil
        streamingMessageId = nil   // triggers final full-Markdown render
    }

    private func finish(_ err: Error?, assistantId: UUID) {
        endStreaming()
        isLoading = false
        stopTimer()
        if let i = messages.firstIndex(where: { $0.id == assistantId }) {
            messages[i].elapsed = elapsed
            if !messages[i].text.isEmpty, !savingMode {   // Saving mode isn't a Hermes session
                sessionEstablished = true   // first real reply = session exists
                if serverManaged, !titleApplied {
                    titleApplied = true
                    HermesClient.shared.setSessionTitle(host: hostForTurn, sessionId: sessionId, title: sessionTitle)
                }
            }
        }
        if let err = err, let i = messages.firstIndex(where: { $0.id == assistantId }), messages[i].text.isEmpty {
            errorText = err.localizedDescription
            messages.remove(at: i)
        }
        archiveToObsidian()
        if notifyWhenDone {
            let summary = errorText.isEmpty ? String(lastAssistantText.prefix(120)) : errorText
            Notifier.notify(
                title: isArabic ? "هيرميس خلّص ✅" : "Hermes finished ✅",
                body: summary.isEmpty ? (isArabic ? "تمّت المهمة" : "Task done") : summary
            )
            onTaskFinishedNotify?()
        }
        // A message was queued while this turn ran → send it now as a new turn.
        if let q = queued, !q.isEmpty {
            queued = nil
            input = q
            send()
        } else if errorText.isEmpty, !lastAssistantText.isEmpty {
            fetchSuggestions()   // offer follow-ups (AI Chat layout only)
        }
    }

    func stop() {
        currentTask?.cancel()
        currentTask = nil
        endStreaming()
        isLoading = false
        stopTimer()
    }

    private func startTimer() {
        startDate = Date()
        elapsed = 0
        timerCancellable = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()
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

    // MARK: Obsidian archive

    func archiveToObsidian() {
        let vault = UserDefaults.standard.string(forKey: "hb.obsidian") ?? ""
        guard !vault.isEmpty, messages.contains(where: { !$0.text.isEmpty }) else { return }

        let dir = (vault as NSString).appendingPathComponent("HermesBar")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let firstQ = messages.first(where: { $0.role == "user" })?.text ?? "conversation"
        if noteFilename == nil {
            let slug = String(firstQ.prefix(40))
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HHmm"
            noteFilename = "\(df.string(from: Date())) \(slug).md"
        }
        guard let name = noteFilename else { return }

        var md = "# \(String(firstQ.prefix(60)))\n\n"
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
        md += "> \(df.string(from: Date())) · HermesBar\n\n"
        for m in messages where !m.text.isEmpty {
            let who = m.role == "user" ? "🙋 " + (isArabic ? "أنت" : "You") : "🤖 Hermes"
            md += "## \(who)\n\n\(m.text)\n\n"
        }
        let path = (dir as NSString).appendingPathComponent(name)
        try? md.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

// MARK: - Panel controller

final class AskPanelController: NSObject, NSWindowDelegate {
    private var panel: FloatingPanel?
    private let viewModel = AskViewModel()
    private var cancellables = Set<AnyCancellable>()
    private let defaultSize = NSSize(width: 720, height: 520)
    private var ignoreResignUntil: Date = .distantPast   // keeps the panel from flash-dismissing
    private var hasPositioned = false                    // place once, then preserve position

    var onClosed: (() -> Void)?                          // AppDelegate removes us when destroyed

    var isVisible: Bool { panel?.isVisible ?? false }
    var isKey: Bool { panel?.isKeyWindow ?? false }

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
        viewModel.refreshFromSettings()
        viewModel.onClose = { [weak self] in self?.dismiss() }
        viewModel.onTaskFinishedNotify = { [weak self] in
            guard let self = self else { return }
            NotificationCenter.default.post(name: .hbPendingResult, object: self)
        }
        ensurePanel()
        applyPinBehavior()
        applyAppearance()
        // Centre only the first time; afterwards the window reappears exactly where
        // the user left it (e.g. a screen corner), preserving position on Show.
        if !hasPositioned {
            position(panel!)
            hasPositioned = true
        }
        NSApp.activate(ignoringOtherApps: true)
        panel!.makeKeyAndOrderFront(nil)
    }

    // Tapping the "done" notification lands here. Give the panel a brief grace
    // period so it doesn't auto-dismiss while the previous app still holds focus.
    func presentShowingResult() {
        ignoreResignUntil = Date().addingTimeInterval(0.8)
        present()
    }

    func dismiss() {
        // Pure hide — position + conversation are preserved so Show brings it back
        // exactly as it was.
        panel?.orderOut(nil)
    }

    // Close hotkey: permanently destroy this window. Archive the chat, tear down the
    // panel for good, and notify the app so it drops us from its window list — so it
    // can NEVER reappear on a later Show (no hidden leftovers piling up).
    func destroy() {
        viewModel.stop()
        viewModel.archiveToObsidian()
        cancellables.removeAll()
        if let p = panel {
            p.delegate = nil
            p.orderOut(nil)
            p.close()
        }
        panel = nil
        onClosed?()
    }

    func applyTheme() { viewModel.refreshFromSettings(); applyAppearance() }

    // Follow the user's appearance choice (system / dark / light) at the window level
    // so the glass material + native chrome flip too, not just SwiftUI content.
    private func applyAppearance() {
        switch Settings.shared.appearanceMode {
        case "dark":  panel?.appearance = NSAppearance(named: .darkAqua)
        case "light": panel?.appearance = NSAppearance(named: .aqua)
        default:      panel?.appearance = nil
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        if Date() < ignoreResignUntil { return }
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
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let x = visible.midX - size.width / 2
        let y = visible.maxY - size.height - visible.height * 0.14
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - SwiftUI content

// One rendered segment of an assistant reply: prose or a fenced code block.
struct MsgSeg: Identifiable { let id = UUID(); let isCode: Bool; let content: String; let lang: String }

struct AskView: View {
    @ObservedObject var vm: AskViewModel
    @State private var dropTargeted = false
    @State private var showMinimalControls = false
    @State private var showAllHistory = false
    @State private var copiedMessageId: UUID?
    @State private var copiedCodeId: UUID?
    @State private var showKanban = false
    @State private var kanbanInput = ""
    @ObservedObject private var kanban = KanbanStore.shared
    @State private var showSchedule = false
    @State private var scheduleDate = Date()
    @State private var scheduleText = ""

    private let historyCap = 30   // render only recent turns in the light panel

    private var t: Theme { vm.theme }
    private var ar: Bool { vm.isArabic }

    var body: some View {
        ZStack {
            baseBackground
            auroraOrThinkingLayer          // living lights (behind content)
            layoutBody
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .topTrailing) { serverBadge }
        .overlay(dropHighlight)
        .overlay { if showKanban { kanbanOverlay } }
        .overlay { if showSchedule { scheduleOverlay } }
        .animation(.easeInOut(duration: 0.6), value: vm.isLoading)   // gradual light fade
        .preferredColorScheme(colorSchemeForMode)
        .environment(\.layoutDirection, ar ? .rightToLeft : .leftToRight)
        .onExitCommand { vm.onClose?() }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in handleDrop(providers) }
    }

    // Destination badge — visible ONLY when messages route to the server, so the
    // default (local) stays clutter-free. A tiny glass capsule with a live dot;
    // tapping it flips back to local (same action as the 🔗 icon).
    @ViewBuilder private var serverBadge: some View {
        if Settings.shared.useServer && !Settings.shared.serverHost.isEmpty {
            Button(action: { toggleServer() }) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(t.accent)
                        .frame(width: 6, height: 6)
                        .shadow(color: t.accent.opacity(0.8), radius: 3)
                    Text(ar ? "سيرفر" : "Server")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(t.textPrimary.opacity(0.85))
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(t.surface.opacity(0.85)))
                .overlay(Capsule().strokeBorder(t.accent.opacity(0.35), lineWidth: 1))
            }
            .buttonStyle(SpringPopButtonStyle())
            .help(ar ? "رسائلك تروح للسيرفر — اضغط للتبديل للمحلي" : "Messages go to the server — tap to switch to local")
            .padding(10)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
    }

    // Appearance override: nil = follow the system (macOS light/dark).
    private var colorSchemeForMode: ColorScheme? {
        switch Settings.shared.appearanceMode {
        case "dark":  return .dark
        case "light": return .light
        default:      return nil
        }
    }

    // The living-lights layer: an always-on hero in Aurora Canvas; thinking-only in
    // the other layouts. Fades in/out gradually (never a hard cut).
    @ViewBuilder private var auroraOrThinkingLayer: some View {
        let sp = Settings.shared.thinkingSpeed
        let it = Settings.shared.thinkingIntensity
        if vm.layout == .aurora {
            RadialAurora(speed: sp, intensity: it * (vm.isLoading ? 1.0 : 0.55))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else if vm.isLoading {
            thinkingBackground
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .transition(.opacity)
        }
    }

    @ViewBuilder private var layoutBody: some View {
        switch vm.layout {
        case .classic: classicLayout
        case .chat:    chatLayout
        case .rail:    railLayout
        case .minimal: minimalLayout
        case .aurora:  auroraLayout
        case .commandDeck: commandDeckLayout
        case .palette: paletteLayout
        case .aiChat: aiChatLayout
        }
    }

    // AI Chat — faithful to the reference: a header (title + actions), the thread,
    // a rounded composer with a model pill and an action row, and a footer note.
    private var aiChatLayout: some View {
        VStack(spacing: 8) {
            aiHeader
            Divider().opacity(0.12)
            contentArea
            if !vm.attachments.isEmpty { attachmentsRow }
            aiComposer
            Text(ar ? "قد يخطئ هيرميس — راجع المعلومات المهمة." : "Hermes can make mistakes — verify important info.")
                .font(.system(size: 10)).foregroundColor(t.textSecondary.opacity(0.7))
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // Tappable AI-generated follow-up questions (the "→ question" list from the ref).
    private var aiSuggestions: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(vm.suggestions, id: \.self) { s in
                Button { vm.input = s; vm.send() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.right").font(.system(size: 11)).foregroundColor(t.accent)
                        Text(s).font(.system(size: 13)).foregroundColor(t.textPrimary).lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(t.surface.opacity(0.4)))
                }.buttonStyle(SpringPopButtonStyle())
            }
        }
    }

    private var aiHeader: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.and.text.bubble.right").foregroundColor(t.textSecondary).font(.system(size: 13))
                Text(ar ? "محادثة جديدة" : "New AI chat").font(.system(size: 14, weight: .semibold)).foregroundColor(t.textPrimary)
                Image(systemName: "chevron.down").font(.system(size: 10)).foregroundColor(t.textSecondary)
            }
            Spacer()
            aiHeaderBtn("square.and.pencil", ar ? "جديد" : "New") { vm.newChat() }
            aiHeaderBtn(vm.withScreenshot ? "eye.fill" : "eye.slash", ar ? "الشاشة" : "Screen") { vm.setWithScreenshot(!vm.withScreenshot) }
            aiHeaderBtn("square.and.arrow.up", ar ? "مشاركة" : "Share") { shareText(vm.lastAssistantText) }
            aiHeaderBtn("macwindow.on.rectangle", ar ? "ديسكتوب" : "Desktop") { openHermesDesktop() }
        }
    }

    private func aiHeaderBtn(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12)).foregroundColor(t.textSecondary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(t.surface.opacity(0.5)))
                .overlay(Circle().strokeBorder(t.textSecondary.opacity(0.15)))
        }.buttonStyle(SpringPopButtonStyle()).help(help)
    }

    private var aiComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let q = vm.queued, !q.isEmpty { queuedBanner(q) }
            ZStack(alignment: .topLeading) {
                if vm.input.isEmpty {
                    Text(vm.isLoading ? (ar ? "اكتب وسيُرسل تلقائياً…" : "Type — auto-sends…") : (ar ? "اسأل هيرميس أي شيء…" : "Ask Hermes anything…"))
                        .foregroundColor(t.textSecondary).font(.system(size: 15)).padding(.top, 2).allowsHitTesting(false)
                }
                MultilineInput(text: $vm.input, textColor: NSColor(t.textPrimary), onSend: { vm.send() })
                    .frame(minHeight: 24, maxHeight: 90)
            }
            HStack(spacing: 8) {
                aiCircleBtn("plus") { openFilePicker() }
                modelPicker
                aiCircleBtn(vm.savingMode ? "leaf.fill" : "brain") { vm.toggleSaving() }
                if vm.savingMode { aiCircleBtn(vm.webSearch ? "globe" : "globe.badge.chevron.backward") { vm.toggleWebSearch() } }
                if !moreIconIds.isEmpty { moreIconsMenu }
                Spacer()
                sendOrStop
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(t.surface.opacity(0.5))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(t.textSecondary.opacity(0.16), lineWidth: 1)))
    }

    private func aiCircleBtn(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13)).foregroundColor(t.textSecondary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(t.surface.opacity(0.55)))
                .overlay(Circle().strokeBorder(t.textSecondary.opacity(0.15)))
        }.buttonStyle(SpringPopButtonStyle())
    }

    // Command Palette — faithful to the Raycast-style reference: a search-style input
    // at the TOP, a row of quick filter chips, the results/thread, and a bottom hint
    // bar with keycaps. A totally different shape from the chat layouts.
    private var paletteLayout: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(t.textSecondary).font(.system(size: 15)).padding(.top, 3)
                ZStack(alignment: .topLeading) {
                    if vm.input.isEmpty {
                        Text(ar ? "اكتب أمراً أو سؤالاً…" : "Search or type a command…")
                            .foregroundColor(t.textSecondary).font(.system(size: 16)).padding(.top, 2).allowsHitTesting(false)
                    }
                    MultilineInput(text: $vm.input, textColor: NSColor(t.textPrimary), onSend: { vm.send() })
                        .frame(minHeight: 22, maxHeight: 80)
                }
                sendOrStop
            }
            if let q = vm.queued, !q.isEmpty { queuedBanner(q) }
            Divider().opacity(0.15)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) { paletteChips }
            }
            if !vm.attachments.isEmpty { attachmentsRow }

            contentArea

            Divider().opacity(0.15)
            HStack(spacing: 14) {
                keycapHint("return", ar ? "إرسال" : "Send")
                keycapHint("arrow.up", ar ? "سطر جديد ⇧" : "New line ⇧")
                keycapHint("escape", ar ? "إغلاق" : "Close")
                Spacer()
                modelPicker
            }
        }
    }

    // Labelled filter chips (Raycast-style) mapping to our key modes/tools.
    @ViewBuilder private var paletteChips: some View {
        paletteChip(vm.savingMode ? "leaf.fill" : "brain", vm.savingMode ? (ar ? "توفير" : "Saving") : (ar ? "عميق" : "Deep"), vm.savingMode) { vm.toggleSaving() }
        if vm.savingMode {
            paletteChip("globe", ar ? "بحث" : "Web", vm.webSearch) { vm.toggleWebSearch() }
        }
        paletteChip(vm.withScreenshot ? "eye.fill" : "eye.slash", ar ? "الشاشة" : "Screen", vm.withScreenshot) { vm.setWithScreenshot(!vm.withScreenshot) }
        paletteChip("paperclip", ar ? "إرفاق" : "Attach", false) { openFilePicker() }
        paletteChip("checklist", ar ? "مهمة" : "Task", false) { vm.applyTaskPrefix() }
        paletteChip("calendar.badge.clock", ar ? "جدولة" : "Schedule", false) { vm.applySchedulePrefix() }
        paletteChip("square.and.pencil", ar ? "جديد" : "New", false) { vm.newChat() }
    }

    private func paletteChip(_ icon: String, _ label: String, _ active: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11))
                Text(label).font(.system(size: 12))
            }
            .foregroundColor(active ? t.accent : t.textSecondary)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(active ? t.accent.opacity(0.15) : t.surface.opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(t.textSecondary.opacity(0.16), lineWidth: 1))
        }.buttonStyle(SpringPopButtonStyle())
    }

    private func keycapHint(_ symbol: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10, weight: .medium))
                .frame(width: 18, height: 16)
                .background(RoundedRectangle(cornerRadius: 4).fill(t.surface.opacity(0.6)))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(t.textSecondary.opacity(0.2)))
            Text(label).font(.system(size: 11))
        }
        .foregroundColor(t.textSecondary)
    }

    // Command Deck — a two-pane cockpit: a labelled sidebar (New chat · Tools ·
    // Model) on one side, the conversation + composer on the other. Structurally the
    // opposite of the single-column layouts.
    private var commandDeckLayout: some View {
        HStack(alignment: .top, spacing: 0) {
            deckSidebar
                .frame(width: 178)
                .frame(maxHeight: .infinity, alignment: .top)
            Divider().opacity(0.15)
            VStack(spacing: 8) {
                contentArea
                if !vm.attachments.isEmpty { attachmentsRow }
                deckComposer
            }
            .padding(.horizontal, 12)
        }
    }

    private var deckSidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundColor(t.accent).font(.system(size: 14, weight: .semibold))
                Text("Hermes").font(.system(size: 15, weight: .bold)).foregroundColor(t.textPrimary)
            }
            deckButton("square.and.pencil", ar ? "محادثة جديدة" : "New chat") { vm.newChat() }
                .keyboardShortcut("n", modifiers: .command)

            deckSectionHeader(ar ? "أدوات" : "Tools")
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(deckToolIds, id: \.self) { id in deckToolRow(id) }
                }
            }
            deckSectionHeader(ar ? "المودل" : "Model")
            HStack { modelPicker; Spacer() }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // Tools shown in the deck sidebar (respects hidden set; New-chat is its own button).
    private var deckToolIds: [String] {
        PanelIcon.all.map { $0.id }.filter { id in
            guard !iconHidden(id), id != "newchat" else { return false }
            if id == "web" { return vm.savingMode }
            return true
        }
    }

    private func deckToolActive(_ id: String) -> Bool {
        switch id {
        case "mode":   return vm.savingMode
        case "web":    return vm.webSearch
        case "screen": return vm.withScreenshot
        case "pin":    return vm.pinMode != .off
        case "notify": return vm.notifyWhenDone
        default:       return false
        }
    }

    private func deckToolRow(_ id: String) -> some View {
        let icon = PanelIcon.all.first { $0.id == id }
        let active = deckToolActive(id)
        return Button { triggerIcon(id) } label: {
            HStack(spacing: 8) {
                Image(systemName: icon?.symbol ?? "circle").font(.system(size: 12)).frame(width: 18)
                Text(icon?.title(ar) ?? id).font(.system(size: 12)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundColor(active ? t.accent : t.textSecondary)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(active ? t.accent.opacity(0.14) : Color.clear))
        }.buttonStyle(SpringPopButtonStyle())
    }

    private func deckSectionHeader(_ s: String) -> some View {
        Text(s.uppercased())
            .font(.system(size: 10, weight: .bold)).foregroundColor(t.textSecondary.opacity(0.7)).kerning(0.5)
    }

    private func deckButton(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 12, weight: .medium))
                Text(label).font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundColor(t.textPrimary)
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(t.surface.opacity(0.55)))
        }.buttonStyle(SpringPopButtonStyle())
    }

    private var deckComposer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            inputField
            sendOrStop
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(t.surface.opacity(0.5))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(t.textSecondary.opacity(0.15), lineWidth: 1)))
    }

    // Aurora Canvas — a distinct, roomy layout: minimal top bar, an airy answer area
    // over the living aurora, and a big rounded composer card at the bottom.
    private var auroraLayout: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundColor(t.accent).font(.system(size: 13, weight: .semibold))
                Text("Hermes").font(.system(size: 13, weight: .semibold)).foregroundColor(t.textSecondary)
                Spacer()
                modelPicker
            }
            .padding(.bottom, 6)

            contentArea.frame(maxWidth: .infinity, maxHeight: .infinity)

            if !vm.attachments.isEmpty { attachmentsRow }

            VStack(alignment: .leading, spacing: 8) {
                inputField
                HStack(spacing: 7) {
                    controlIcons
                    Spacer()
                    sendOrStop
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(t.surface.opacity(0.55))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(t.textSecondary.opacity(0.18), lineWidth: 1))
            )
            .padding(.top, 6)
        }
    }

    // Input on top, tools, thread, mode bar at the bottom (original).
    private var classicLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            inputField
            controlRow
            if !vm.attachments.isEmpty { attachmentsRow }
            Divider().opacity(0.15)
            contentArea
            modeBar
        }
    }

    // Thread fills the top, input pinned at the bottom (messenger style).
    private var chatLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            contentArea
            Divider().opacity(0.15)
            if !vm.attachments.isEmpty { attachmentsRow }
            inputField
            controlRow
            modeBar
        }
    }

    // Vertical icon rail on the side, thread + input in the main column.
    private var railLayout: some View {
        HStack(alignment: .top, spacing: 12) {
            controlRail.padding(.top, 2)
            Divider().opacity(0.15)
            VStack(alignment: .leading, spacing: 8) {
                inputField
                if !vm.attachments.isEmpty { attachmentsRow }
                Divider().opacity(0.15)
                contentArea
                modeBar
            }
        }
    }

    // Just input + answer; tools hidden behind an ellipsis popover.
    private var minimalLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                inputField
                sendOrStop
                minimalMenu
            }
            if !vm.attachments.isEmpty { attachmentsRow }
            Divider().opacity(0.15)
            contentArea
        }
    }

    @ViewBuilder private var thinkingBackground: some View {
        let sp = Settings.shared.thinkingSpeed
        let it = Settings.shared.thinkingIntensity
        switch ThinkingStyle(rawValue: Settings.shared.thinkingStyle) ?? .topWash {
        case .topWash:      ThinkingWash(speed: sp, intensity: it)
        case .radialAurora: RadialAurora(speed: sp, intensity: it)
        default:            EmptyView()
        }
    }

    @ViewBuilder private var baseBackground: some View {
        if t.isGlass {
            // Dark frosted glass: blur + a per-theme dark tint so the panel reads as
            // deep glass regardless of the wallpaper behind it.
            ZStack {
                VisualEffectBackground()
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(colors: [Color.black.opacity(min(t.glassShade + 0.12, 0.9)),
                                                  Color.black.opacity(t.glassShade)],
                                         startPoint: .top, endPoint: .bottom))
            }
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
        } else {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(t.background)
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(t.accent.opacity(0.25), lineWidth: 1))
        }
    }

    @ViewBuilder private var dropHighlight: some View {
        if dropTargeted {
            RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(t.accent, lineWidth: 2)
        }
    }

    private var placeholder: String {
        ar ? "وش تحتاج مساعدة فيه؟ (Shift+Enter لسطر جديد)" : "What do you need help with?"
    }

    private var inputField: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let q = vm.queued, !q.isEmpty { queuedBanner(q) }
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "sparkles").foregroundColor(t.accent).font(.system(size: 16, weight: .semibold)).padding(.top, 3)
                ZStack(alignment: .topLeading) {
                    if vm.input.isEmpty {
                        Text(vm.isLoading ? (ar ? "اكتب وسيُرسل تلقائياً بعد ما يخلّص…" : "Type — auto-sends when it finishes…") : placeholder)
                            .foregroundColor(t.textSecondary).font(.system(size: 16)).padding(.top, 2).allowsHitTesting(false)
                    }
                    MultilineInput(text: $vm.input, textColor: NSColor(t.textPrimary), onSend: { vm.send() })
                        .frame(minHeight: 22, maxHeight: 100)
                }
            }
        }
    }

    // Shows the message waiting to auto-send when the current turn finishes.
    private func queuedBanner(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath").font(.system(size: 11))
            Text((ar ? "مجدوَل: " : "Queued: ") + String(text.prefix(60))).font(.system(size: 11)).lineLimit(1)
            Spacer()
            Button { vm.queued = nil } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 11))
            }.buttonStyle(.plain)
        }
        .foregroundColor(t.textSecondary)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(t.accent.opacity(0.14)))
    }

    private func iconHidden(_ id: String) -> Bool { Settings.shared.isIconHidden(id) }

    // Icons the user keeps ON the surface vs the ones tucked under "⋯ More".
    private var surfaceIconIds: [String] { PanelIcon.all.map { $0.id }.filter { !iconHidden($0) } }
    private var moreIconIds: [String]    { PanelIcon.all.map { $0.id }.filter {  iconHidden($0) } }

    // One control icon addressed by id (surface chip with live state + spring).
    @ViewBuilder private func controlIcon(_ id: String) -> some View {
        switch id {
        case "newchat":
            iconButton("square.and.pencil", active: false, help: ar ? "محادثة جديدة (⌘N)" : "New chat (⌘N)") { vm.newChat() }
                .keyboardShortcut("n", modifiers: .command)
        case "mode":
            iconButton(vm.savingMode ? "leaf.fill" : "brain", active: vm.savingMode,
                       help: vm.savingMode ? (ar ? "وضع التوفير (رخيص/مباشر) — اضغط للعميق" : "Saving mode — tap for Deep")
                                           : (ar ? "وضع عميق (هيرميس كامل) — اضغط للتوفير" : "Deep mode — tap for Saving")) { vm.toggleSaving() }
        case "web":
            if vm.savingMode {
                iconButton(vm.webSearch ? "globe" : "globe.badge.chevron.backward", active: vm.webSearch,
                           help: ar ? "بحث ويب في وضع التوفير" : "Web search in Saving mode") { vm.toggleWebSearch() }
            }
        case "attach":
            iconButton("paperclip", active: false, help: ar ? "إرفاق ملف أو صورة" : "Attach file or image") { openFilePicker() }
        case "scrape":
            iconButton("doc.text.magnifyingglass", active: false, help: ar ? "قراءة/فحص سريع (Scrapling)" : "Quick read") { vm.applySpiderPrefix() }
        case "screen":
            iconButton(vm.withScreenshot ? "eye.fill" : "eye.slash", active: vm.withScreenshot, help: ar ? "رؤية الشاشة" : "See screen") { vm.setWithScreenshot(!vm.withScreenshot) }
        case "pin":
            iconButton(pinIcon, active: vm.pinMode != .off, help: pinHelp) { vm.cyclePinMode() }
        case "notify":
            iconButton(vm.notifyWhenDone ? "bell.fill" : "bell.slash", active: vm.notifyWhenDone, help: ar ? "أشعرني لما يخلّص" : "Notify when done") { vm.toggleNotify() }
        case "spawn":
            iconButton("plus.rectangle.on.rectangle", active: false, help: ar ? "نافذة هيرميس جديدة (مستقلة)" : "New Hermes window") {
                NotificationCenter.default.post(name: .hbSpawnWindow, object: nil)
            }
        case "desktop":
            iconButton("macwindow.on.rectangle", active: false, help: ar ? "افتح هيرميس ديسكتوب" : "Open Hermes Desktop") { openHermesDesktop() }
        case "tasks":
            iconButton("checklist", active: showKanban, help: ar ? "لوحة Kanban (بطاقات)" : "Kanban board (cards)") { showKanban.toggle() }
        case "schedule":
            iconButton("calendar.badge.clock", active: showSchedule, help: ar ? "جدولة تذكير" : "Schedule a reminder") { showSchedule.toggle() }
        case "server":
            iconButton(Settings.shared.useServer ? "link.circle.fill" : "link",
                       active: Settings.shared.useServer,
                       help: Settings.shared.useServer ? (ar ? "الوجهة: السيرفر 🖥️ — اضغط للتبديل للمحلي" : "Destination: Server — tap for Local")
                                                       : (ar ? "الوجهة: محلي 💻 — اضغط للتبديل للسيرفر" : "Destination: Local — tap for Server")) {
                toggleServer()
            }
        default:
            EmptyView()
        }
    }

    private func toggleServer() {
        Settings.shared.useServer.toggle()
        Settings.shared.save()   // posts didChange → panel refreshes the icon state
    }

    // Perform an icon's action from the "⋯ More" menu.
    private func triggerIcon(_ id: String) {
        switch id {
        case "newchat": vm.newChat()
        case "mode":    vm.toggleSaving()
        case "web":     vm.toggleWebSearch()
        case "attach":  openFilePicker()
        case "scrape":  vm.applySpiderPrefix()
        case "screen":  vm.setWithScreenshot(!vm.withScreenshot)
        case "pin":     vm.cyclePinMode()
        case "notify":  vm.toggleNotify()
        case "spawn":   NotificationCenter.default.post(name: .hbSpawnWindow, object: nil)
        case "desktop": openHermesDesktop()
        case "tasks":   showKanban.toggle()
        case "schedule": showSchedule.toggle()
        case "server":  toggleServer()
        default: break
        }
    }

    // Surface icons + a "⋯ More" popover holding the ones moved off the surface.
    @ViewBuilder private var controlIcons: some View {
        ForEach(surfaceIconIds, id: \.self) { controlIcon($0) }
        if !moreIconIds.isEmpty { moreIconsMenu }
    }

    private var moreIconsMenu: some View {
        Menu {
            ForEach(moreIconIds, id: \.self) { id in
                if let icon = PanelIcon.all.first(where: { $0.id == id }) {
                    Button { triggerIcon(id) } label: { Label(icon.title(ar), systemImage: icon.symbol) }
                }
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 14, weight: .medium))
                .foregroundColor(t.textSecondary)
                .frame(width: 30, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(t.surface.opacity(0.55)))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(t.textSecondary.opacity(0.16), lineWidth: 1))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(ar ? "أدوات أكثر" : "More tools")
    }

    @ViewBuilder private var sendOrStop: some View {
        if vm.isLoading {
            Button(action: { vm.stop() }) {
                Image(systemName: "stop.circle.fill").font(.system(size: 22)).foregroundColor(.red)
            }.buttonStyle(.plain).help(ar ? "إيقاف" : "Stop")
        } else {
            Button(action: { vm.send() }) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 22))
                    .foregroundColor(canSend ? t.accent : t.textSecondary.opacity(0.4))
            }.buttonStyle(.plain).disabled(!canSend)
        }
    }

    private var controlRow: some View {
        HStack(spacing: 7) {
            controlIcons
            Spacer()
            sendOrStop
        }
    }

    private var controlRail: some View {
        VStack(spacing: 16) {
            controlIcons
            Spacer()
            sendOrStop
        }
        .frame(maxHeight: .infinity)
    }

    // Minimal layout hides the tools behind an ellipsis popover.
    private var minimalMenu: some View {
        Button(action: { showMinimalControls.toggle() }) {
            Image(systemName: "ellipsis.circle").font(.system(size: 20)).foregroundColor(t.textSecondary)
        }
        .buttonStyle(.plain)
        .help(ar ? "أدوات" : "Tools")
        .popover(isPresented: $showMinimalControls, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 18) { controlIcons }
                .padding(16)
                .background(t.background)
        }
    }

    // Raycast-style icon chip: rounded-rect with a subtle fill + hairline border.
    private func iconButton(_ name: String, active: Bool, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 14, weight: .medium))
                .foregroundColor(active ? t.accent : t.textSecondary)
                .frame(width: 30, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(active ? t.accent.opacity(0.16) : t.surface.opacity(0.55)))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(t.textSecondary.opacity(active ? 0.0 : 0.16), lineWidth: 1))
        }.buttonStyle(SpringPopButtonStyle()).help(help)
    }

    private var canSend: Bool {
        !vm.input.trimmingCharacters(in: .whitespaces).isEmpty || !vm.attachments.isEmpty
    }

    // Attachments as clean source-cards: a tinted icon tile + middle-truncated name.
    private var attachmentsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(vm.attachments) { att in
                    HStack(spacing: 8) {
                        Image(systemName: att.symbol)
                            .font(.system(size: 15)).foregroundColor(t.accent)
                            .frame(width: 30, height: 30)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(t.accent.opacity(0.15)))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(att.name)
                                .font(.system(size: 12, weight: .medium)).foregroundColor(t.textPrimary)
                                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 130, alignment: .leading)
                            Text(att.isDirectory ? (ar ? "مجلد" : "Folder")
                                                 : (att.url.pathExtension.isEmpty ? (ar ? "ملف" : "File") : att.url.pathExtension.uppercased()))
                                .font(.system(size: 10)).foregroundColor(t.textSecondary)
                        }
                        Button(action: { vm.removeAttachment(att) }) {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundColor(t.textSecondary)
                        }.buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(t.surface.opacity(0.55)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(t.textSecondary.opacity(0.15), lineWidth: 1))
                }
            }
            .padding(.vertical, 1)
        }
        .frame(maxHeight: 52)
    }

    private var visibleMessages: [ChatMessage] {
        (showAllHistory || vm.messages.count <= historyCap) ? vm.messages : Array(vm.messages.suffix(historyCap))
    }
    private var hiddenCount: Int {
        showAllHistory ? 0 : max(0, vm.messages.count - historyCap)
    }

    private var contentArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if hiddenCount > 0 {
                        Button(action: { showAllHistory = true }) {
                            HStack(spacing: 5) {
                                Image(systemName: "chevron.up")
                                Text(ar ? "عرض \(hiddenCount) رسالة أقدم" : "Show \(hiddenCount) earlier messages")
                            }
                            .font(.system(size: 12)).foregroundColor(t.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)
                    }
                    ForEach(visibleMessages) { msg in
                        messageView(msg).id(msg.id)
                    }
                    if vm.isLoading, (vm.messages.last?.text.isEmpty ?? false) {
                        loadingIndicator
                    }
                    if !vm.errorText.isEmpty {
                        Text(vm.errorText).font(.system(size: 14)).foregroundColor(.red).textSelection(.enabled)
                    }
                    if !vm.suggestions.isEmpty { aiSuggestions }
                    Color.clear.frame(height: 1).id("BOTTOM_ANCHOR")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay(alignment: .bottomTrailing) {
                // In RTL, trailing = visual LEFT (where the user wants it). Loop-free:
                // shown once there's a conversation. (Geometry-based "hide at bottom"
                // caused a render feedback loop / hang — removed.)
                if vm.messages.count >= 2 { scrollDownButton(proxy) }
            }
        }
    }

    // Left-aligned, semi-transparent circular button that jumps to the last line.
    // Only visible when scrolled up (hidden once you're at the bottom).
    private func scrollDownButton(_ proxy: ScrollViewProxy) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("BOTTOM_ANCHOR", anchor: .bottom) }
        } label: {
            Image(systemName: "arrow.down")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(t.textPrimary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(t.surface.opacity(0.45)))
                .overlay(Circle().strokeBorder(t.textSecondary.opacity(0.22), lineWidth: 1))
        }
        .buttonStyle(SpringPopButtonStyle())
        .padding(.trailing, 6).padding(.bottom, 6)   // trailing = left in RTL
        .transition(.opacity)
        .help(ar ? "النزول لآخر سطر" : "Jump to latest")
    }

    // MARK: - Kanban overlay (local, real cards)

    private var kanbanOverlay: some View {
        ZStack {
            Color.black.opacity(0.35).onTapGesture { showKanban = false }
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "checklist").foregroundColor(t.accent)
                    Text(ar ? "المهام" : "Tasks").font(.system(size: 15, weight: .bold)).foregroundColor(t.textPrimary)
                    Spacer()
                    Button { showKanban = false } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(t.textSecondary)
                    }.buttonStyle(.plain)
                }
                HStack(spacing: 8) {
                    TextField(ar ? "اكتب مهمة وأضفها…" : "Type a task…", text: $kanbanInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { kanban.add(kanbanInput); kanbanInput = "" }
                    Button(ar ? "أضف" : "Add") { kanban.add(kanbanInput); kanbanInput = "" }
                        .buttonStyle(.borderedProminent)
                        .disabled(kanbanInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 8) {
                        ForEach(kanban.cards) { card in kanbanRow(card) }
                        if kanban.cards.isEmpty {
                            Text(ar ? "لا مهام بعد — اكتب وأضف فوق." : "No tasks yet — add one above.")
                                .font(.system(size: 12)).foregroundColor(t.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .center).padding(.top, 20)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: 560, maxHeight: 480)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(t.background))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(t.textSecondary.opacity(0.2), lineWidth: 1))
            .padding(24)
        }
    }

    // MARK: - Schedule overlay (date+time form → sends a cron request to Hermes)

    private var scheduleOverlay: some View {
        ZStack {
            Color.black.opacity(0.35).onTapGesture { showSchedule = false }
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "calendar.badge.clock").foregroundColor(t.accent)
                    Text(ar ? "جدولة تذكير" : "Schedule a reminder").font(.system(size: 15, weight: .bold)).foregroundColor(t.textPrimary)
                    Spacer()
                    Button { showSchedule = false } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(t.textSecondary)
                    }.buttonStyle(.plain)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(ar ? "التاريخ والوقت (اليوم جاهز — عدّل الوقت)" : "Date & time (today prefilled — set the time)")
                        .font(.system(size: 11)).foregroundColor(t.textSecondary)
                    DatePicker("", selection: $scheduleDate, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden().datePickerStyle(.field)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(ar ? "نوع التذكير / النص" : "Reminder text").font(.system(size: 11)).foregroundColor(t.textSecondary)
                    TextField(ar ? "مثال: اجتماع، اتصال، تجربة…" : "e.g. meeting, call, test…", text: $scheduleText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { submitSchedule() }
                }
                HStack {
                    Spacer()
                    Button(ar ? "جدول" : "Schedule") { submitSchedule() }
                        .buttonStyle(.borderedProminent)
                        .disabled(scheduleText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(18)
            .frame(maxWidth: 420)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(t.background))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(t.textSecondary.opacity(0.2), lineWidth: 1))
            .padding(24)
        }
    }

    private func submitSchedule() {
        let txt = scheduleText.trimmingCharacters(in: .whitespaces)
        guard !txt.isEmpty else { return }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en")
        df.dateFormat = "yyyy-MM-dd HH:mm"
        let stamp = df.string(from: scheduleDate)
        vm.input = ar
            ? "جدوِل تذكيراً في هيرميس (cron) بتاريخ ووقت \(stamp): \(txt)"
            : "Schedule a Hermes reminder (cron) at \(stamp): \(txt)"
        vm.send()
        scheduleText = ""
        showSchedule = false
    }

    // A full-width task rectangle: done toggle · text · reorder · delete.
    private func kanbanRow(_ card: KanbanCard) -> some View {
        HStack(spacing: 10) {
            Button { kanban.toggle(card) } label: {
                Image(systemName: card.done ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(card.done ? .green : t.textSecondary)
            }.buttonStyle(.plain)
            Text(card.title)
                .font(.system(size: 13)).foregroundColor(card.done ? t.textSecondary : t.textPrimary)
                .strikethrough(card.done)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 2) {
                Button { kanban.moveUp(card) } label: { Image(systemName: "chevron.up") }.buttonStyle(.plain)
                Button { kanban.moveDown(card) } label: { Image(systemName: "chevron.down") }.buttonStyle(.plain)
            }.font(.system(size: 10)).foregroundColor(t.textSecondary)
            Button { kanban.remove(card) } label: { Image(systemName: "trash").foregroundColor(.red) }.buttonStyle(.plain)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(t.surface.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(t.textSecondary.opacity(0.15), lineWidth: 1))
    }

    @ViewBuilder private func messageView(_ msg: ChatMessage) -> some View {
        if msg.role == "user" {
            VStack(alignment: .trailing, spacing: 2) {
                HStack {
                    Spacer(minLength: 40)
                    Text(msg.text)
                        .font(.system(size: 15))
                        .foregroundColor(t.textPrimary)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(t.surface))
                }
                copyButton(id: msg.id, text: msg.text)
            }
        } else if !msg.text.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                if msg.id == vm.streamingMessageId {
                    // Cheap live rendering while tokens stream in.
                    Text(msg.text)
                        .font(.system(size: 16))
                        .foregroundColor(t.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    // MarkdownUI handles wrapping, resize, RTL, and lists/headings
                    // consistently. Code blocks use our styled block (rectangle + copy
                    // button). "Copy all" copies clean text via SelectableAttributedText.plain.
                    Markdown(msg.text)
                        .markdownTextStyle { ForegroundColor(t.textPrimary); FontSize(16) }
                        .markdownBlockStyle(\.codeBlock) { configuration in codeBlock(configuration) }
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    messageActions(msg)
                }
            }
        }
    }

    // Icon-only action bar under every finished assistant message (Gemini-style):
    // copy · copy-code · share · regenerate · 👍 · 👎 · more.
    private func messageActions(_ msg: ChatMessage) -> some View {
        let up = vm.ratings[msg.id] == 1
        let down = vm.ratings[msg.id] == -1
        let copied = copiedMessageId == msg.id
        let codeCopied = copiedCodeId == msg.id
        return HStack(spacing: 8) {
            iconAction(copied ? "checkmark" : "doc.on.doc",
                       help: copied ? (ar ? "تم" : "Copied") : (ar ? "نسخ" : "Copy"),
                       active: copied) {
                copyToPasteboard(SelectableAttributedText.plain(msg.text)); flashCopy(msg.id, code: false)
            }
            if msg.text.contains("```") {
                iconAction(codeCopied ? "checkmark" : "curlybraces",
                           help: ar ? "نسخ الكود" : "Copy code", active: codeCopied) {
                    copyToPasteboard(extractCode(msg.text)); flashCopy(msg.id, code: true)
                }
            }
            iconAction("square.and.arrow.up", help: ar ? "مشاركة" : "Share") { shareText(msg.text) }
            iconAction("arrow.clockwise", help: ar ? "اسأل مرة ثانية" : "Ask again") { vm.regenerate(msg.id) }
            iconAction(up ? "hand.thumbsup.fill" : "hand.thumbsup",
                       help: ar ? "رد ممتاز (يبلّغ هيرميس أن أعجبني)" : "Good answer", active: up) {
                vm.rate(msg.id, up: true)
            }
            iconAction(down ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                       help: ar ? "رد سيئ (يبلّغ هيرميس أنه لم يعجبني)" : "Bad answer", active: down) {
                vm.rate(msg.id, up: false)
            }
            moreMenu(msg)
            Spacer()
            if msg.elapsed > 0 {
                Text(elapsedLabel(msg.elapsed)).font(.system(size: 11)).foregroundColor(t.textSecondary.opacity(0.8))
            }
        }
        .padding(.top, 2)
    }

    // The overflow menu: summarize · open in Desktop.
    private func moreMenu(_ msg: ChatMessage) -> some View {
        Menu {
            Button(ar ? "لخّص" : "Summarize") { vm.summarize(msg.id) }
            Button(ar ? "افتح في هيرميس ديسكتوب" : "Open in Hermes Desktop") { openHermesDesktop() }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 12)).foregroundColor(t.textSecondary)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(t.surface.opacity(0.55)))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(t.textSecondary.opacity(0.14), lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(ar ? "المزيد" : "More")
    }

    // Raycast-style rounded-rect icon button with spring-pop feedback.
    private func iconAction(_ system: String, help: String, active: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system).font(.system(size: 13))
                .foregroundColor(active ? t.accent : t.textSecondary)
                .frame(width: 18, height: 16)
                .padding(.horizontal, 7).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(active ? t.accent.opacity(0.16) : t.surface.opacity(0.55)))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(t.textSecondary.opacity(active ? 0.0 : 0.14), lineWidth: 1))
        }.buttonStyle(SpringPopButtonStyle()).help(help)
    }

    // Flash a ✓ on the copy / copy-code icon for a moment.
    private func flashCopy(_ id: UUID, code: Bool) {
        if code { copiedCodeId = id } else { copiedMessageId = id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            if code { if copiedCodeId == id { copiedCodeId = nil } }
            else { if copiedMessageId == id { copiedMessageId = nil } }
        }
    }

    // Native share sheet for the answer text.
    private func shareText(_ text: String) {
        let picker = NSSharingServicePicker(items: [text])
        if let view = NSApp.keyWindow?.contentView {
            picker.show(relativeTo: .zero, of: view, preferredEdge: .minY)
        }
    }

    // Copy button with a brief ✓ confirmation so you know it copied.
    private func copyButton(id: UUID, text: String, codeOnly: Bool = false) -> some View {
        let copied = (codeOnly ? copiedCodeId : copiedMessageId) == id
        let icon = copied ? "checkmark" : (codeOnly ? "curlybraces" : "doc.on.doc")
        let help = copied ? (ar ? "تم" : "Copied")
                          : (codeOnly ? (ar ? "نسخ الكود" : "Copy code") : (ar ? "نسخ" : "Copy"))
        return iconAction(icon, help: help, active: copied) {
            copyToPasteboard(codeOnly ? extractCode(text) : SelectableAttributedText.plain(text))
            flashCopy(id, code: codeOnly)
        }
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
                }.buttonStyle(.plain)
            }
            Text(modeHint).font(.system(size: 10)).foregroundColor(t.textSecondary.opacity(0.7)).lineLimit(1)
            Spacer()
            modelPicker
        }
    }

    // In-panel model picker — switch the active model without opening Settings.
    // Writes to the Saving or Deep model depending on the current mode.
    private var modelPicker: some View {
        Menu {
            let models = Settings.shared.cachedModels
            if models.isEmpty {
                Text(ar ? "اجلب الموديلات من الإعدادات" : "Fetch models in Settings")
            } else {
                ForEach(models, id: \.self) { m in
                    Button { setActiveModel(m) } label: {
                        if m == currentModelName { Label(m, systemImage: "checkmark") } else { Text(m) }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu").font(.system(size: 10))
                Text(String(currentModelName.prefix(18))).font(.system(size: 11)).lineLimit(1)
            }
            .foregroundColor(t.textSecondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(t.surface.opacity(0.55)))
            .overlay(Capsule().strokeBorder(t.textSecondary.opacity(0.14), lineWidth: 1))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(ar ? "اختر الموديل" : "Choose model")
    }

    private var currentModelName: String {
        let s = Settings.shared
        if vm.savingMode { return s.savingModel.isEmpty ? "—" : s.savingModel }
        return s.deepModel.isEmpty ? "hermes-agent" : s.deepModel
    }

    private func setActiveModel(_ m: String) {
        let s = Settings.shared
        if vm.savingMode { s.savingModel = m } else { s.deepModel = m }
        s.save()   // posts didChange → panel refreshes the label
    }

    private var thinkingPhrases: [String] {
        ar ? ["يقرأ طلبك…", "يجمع أفكاره…", "يجهّز الإجابة…", "يكتب…"]
           : ["Reading your request…", "Gathering thoughts…", "Preparing the answer…", "Writing…"]
    }

    // The "thinking" indicator shown before the first token, styled per the chosen
    // thinking-animation setting.
    @ViewBuilder private var loadingIndicator: some View {
        let style = ThinkingStyle(rawValue: Settings.shared.thinkingStyle) ?? .topWash
        HStack(spacing: 8) {
            switch style {
            case .pulseDots:
                PulseDots(tint: t.accent)
                Text(timerText).font(.system(size: 12)).foregroundColor(t.textSecondary.opacity(0.8))
            case .statusLine:
                PulseDots(tint: t.accent)
                StatusCycler(phrases: thinkingPhrases, tint: t.textSecondary)
            default:
                ProgressView().controlSize(.small)
                Text((ar ? "هيرميس يفكّر… " : "Thinking… ") + timerText)
                    .font(.system(size: 13)).foregroundColor(t.textSecondary)
            }
        }
    }

    private var timerText: String { elapsedLabel(vm.elapsed) }

    private func elapsedLabel(_ e: TimeInterval) -> String {
        let total = Int(e)
        if total >= 60 {
            let m = total / 60, s = total % 60
            return ar ? "⏱ \(m) د \(s) ث" : "⏱ \(m)m \(s)s"
        }
        return String(format: "⏱ %.1f%@", e, ar ? " ث" : "s")
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

    // MARK: helpers

    private func copyToPasteboard(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    // Render an assistant reply: prose runs (selectable, RTL-aware) + code blocks
    // (rectangle with a one-tap copy button).
    @ViewBuilder private func assistantBody(_ text: String) -> some View {
        let segs = splitIntoSegments(text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(segs) { seg in
                if seg.isCode {
                    codeBlockView(seg.content, lang: seg.lang)
                } else if !seg.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    SelectableAttributedText(markdown: seg.content, color: NSColor(t.textPrimary), rtl: ar, fontSize: 16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func splitIntoSegments(_ text: String) -> [MsgSeg] {
        var segs: [MsgSeg] = []
        let parts = text.components(separatedBy: "```")
        for (i, part) in parts.enumerated() {
            if i % 2 == 0 {
                if !part.isEmpty { segs.append(MsgSeg(isCode: false, content: part, lang: "")) }
            } else {
                var body = part
                var lang = ""
                if let nl = body.firstIndex(of: "\n") {
                    lang = String(body[..<nl]).trimmingCharacters(in: .whitespaces)
                    body = String(body[body.index(after: nl)...])
                }
                segs.append(MsgSeg(isCode: true, content: body, lang: lang))
            }
        }
        if segs.isEmpty { segs.append(MsgSeg(isCode: false, content: text, lang: "")) }
        return segs
    }

    // A code block rectangle with a language label + one-tap copy button.
    private func codeBlockView(_ code: String, lang: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(lang.isEmpty ? "code" : lang)
                    .font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundColor(t.textSecondary)
                Spacer()
                CodeCopyButton(code: code, idleColor: t.textSecondary,
                               helpCopy: ar ? "نسخ الكود" : "Copy code",
                               helpDone: ar ? "تم النسخ ✓" : "Copied ✓")
            }
            .padding(.horizontal, 10).padding(.top, 6)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 13, design: .monospaced)).foregroundColor(t.textPrimary)
                    .textSelection(.enabled).padding(10)
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(t.surface))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(t.textSecondary.opacity(0.15), lineWidth: 1))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func codeBlock(_ configuration: CodeBlockConfiguration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(configuration.language?.isEmpty == false ? configuration.language! : "code")
                    .font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundColor(t.textSecondary)
                Spacer()
                CodeCopyButton(code: configuration.content, idleColor: t.textSecondary,
                               helpCopy: ar ? "نسخ الكود" : "Copy code",
                               helpDone: ar ? "تم النسخ ✓" : "Copied ✓")
            }
            .padding(.horizontal, 10).padding(.top, 6)

            ScrollView(.horizontal, showsIndicators: false) {
                configuration.label
                    .markdownTextStyle { FontFamilyVariant(.monospaced); FontSize(13); ForegroundColor(t.textPrimary) }
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
            if let nl = block.firstIndex(of: "\n") { block = String(block[block.index(after: nl)...]) }
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { blocks.append(trimmed) }
            i += 2
        }
        return blocks.joined(separator: "\n\n")
    }

    private func openHermesDesktop() {
        func open(_ args: [String]) -> Int32 {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = args
            try? task.run()
            task.waitUntilExit()
            return task.terminationStatus
        }

        // Deep mode with a real, server-managed Hermes session → open that exact
        // session via the deep link (Desktop loads the full history automatically).
        let hasHermesSession = Settings.shared.serverManagedSessions && vm.sessionEstablished && !vm.savingMode
        if hasHermesSession {
            // Safety net FIRST: even if Desktop accepts the deep link but fails to
            // load the session (version drift), the full transcript is already on
            // the clipboard — one ⌘V and you continue anyway.
            let transcript = vm.transcriptForHandoff()
            if !transcript.isEmpty {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(transcript, forType: .string)
            }
            let link = "hermes://session/\(vm.sessionId)"
            if open([link]) == 0 {
                let title = vm.sessionTitle
                Notifier.notify(
                    title: ar ? "فتح المحادثة في هيرميس ديسكتوب" : "Opening in Hermes Desktop",
                    body: ar ? "إذا ما ظهرت الجلسة\(title.isEmpty ? "" : " «\(title)»")، المحادثة منسوخة — الصقها (⌘V)."
                             : "If the session\(title.isEmpty ? "" : " “\(title)”") doesn't appear, the chat is copied — paste (⌘V)."
                )
                vm.onClose?()
                return
            }
            // Scheme not handled (older Desktop) → fall through to transcript handoff.
        }

        // Saving mode / no Hermes session → hand off the full transcript so you can
        // continue it in Desktop: copy it to the clipboard, then open Hermes to paste.
        let transcript = vm.transcriptForHandoff()
        if !transcript.isEmpty {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(transcript, forType: .string)
            Notifier.notify(
                title: ar ? "المحادثة جاهزة للمتابعة" : "Conversation ready to continue",
                body: ar ? "نُسخت المحادثة — الصقها (⌘V) في هيرميس وأكمل من حيث وقفت."
                         : "Copied — paste (⌘V) into Hermes to continue where you left off."
            )
        }
        _ = open(["-a", "Hermes"])
        vm.onClose?()
    }

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.begin { resp in
            if resp == .OK { for url in panel.urls { vm.addAttachment(url) } }
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
