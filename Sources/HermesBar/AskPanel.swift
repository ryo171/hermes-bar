import AppKit
import SwiftUI
import Combine

// Reasoning-effort levels exposed in the panel's bottom bar.
enum ReasoningLevel: String, CaseIterable {
    case minimal, low, medium, high
    func label(ar: Bool) -> String {
        switch self {
        case .minimal: return ar ? "أدنى" : "Min"
        case .low:     return ar ? "منخفض" : "Low"
        case .medium:  return ar ? "متوسط" : "Med"
        case .high:    return ar ? "عالي" : "High"
        }
    }
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
    @Published var withScreenshot: Bool = true
    @Published var pinned: Bool = false
    @Published var reasoning: String = UserDefaults.standard.string(forKey: "hb.reasoning") ?? "low"

    @Published var theme: Theme = Settings.shared.theme
    @Published var isArabic: Bool = Settings.shared.language == .arabic

    var onClose: (() -> Void)?

    func setReasoning(_ v: String) {
        reasoning = v
        UserDefaults.standard.set(v, forKey: "hb.reasoning")
    }

    func refreshFromSettings() {
        theme = Settings.shared.theme
        isArabic = Settings.shared.language == .arabic
    }

    func reset(withScreenshot: Bool) {
        input = ""
        response = ""
        errorText = ""
        isLoading = false
        self.withScreenshot = withScreenshot
        refreshFromSettings()
    }

    func send() {
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isLoading else { return }
        isLoading = true
        errorText = ""
        response = ""

        let wantsShot = withScreenshot
        let effort = reasoning
        DispatchQueue.global(qos: .userInitiated).async {
            let shot = wantsShot ? Screenshot.captureBase64PNG() : nil
            HermesClient.shared.ask(question: question,
                                    screenshotBase64: shot,
                                    reasoningEffort: effort) { [weak self] result in
                guard let self = self else { return }
                self.isLoading = false
                switch result {
                case .success(let text): self.response = text
                case .failure(let err): self.errorText = err.localizedDescription
                }
            }
        }
    }
}

final class AskPanelController: NSObject, NSWindowDelegate {
    private var panel: FloatingPanel?
    private let viewModel = AskViewModel()
    private let defaultSize = NSSize(width: 720, height: 480)

    var isVisible: Bool { panel?.isVisible ?? false }

    private func savedSize() -> NSSize {
        let d = UserDefaults.standard
        let w = d.double(forKey: "hb.win.w")
        let h = d.double(forKey: "hb.win.h")
        if w >= 460, h >= 240 { return NSSize(width: w, height: h) }
        return defaultSize
    }

    func present(withScreenshot: Bool) {
        viewModel.reset(withScreenshot: withScreenshot)
        viewModel.onClose = { [weak self] in self?.dismiss() }

        if panel == nil {
            let rect = NSRect(origin: .zero, size: savedSize())
            let p = FloatingPanel(contentRect: rect)
            p.contentView = NSHostingView(rootView: AskView(vm: viewModel))
            p.delegate = self
            panel = p
        }
        position(panel!)
        NSApp.activate(ignoringOtherApps: true)
        panel!.makeKeyAndOrderFront(nil)
    }

    func dismiss() { panel?.orderOut(nil) }

    func applyTheme() { viewModel.refreshFromSettings() }

    func windowDidResignKey(_ notification: Notification) {
        if !viewModel.pinned {
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

struct AskView: View {
    @ObservedObject var vm: AskViewModel
    @FocusState private var inputFocused: Bool

    private var t: Theme { vm.theme }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            inputRow
            Divider().opacity(0.15)
            contentArea
            reasoningBar
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(background)
        .environment(\.layoutDirection, vm.isArabic ? .rightToLeft : .leftToRight)
        .onAppear { inputFocused = true }
        .onExitCommand { vm.onClose?() }
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

            Button(action: { vm.pinned.toggle() }) {
                Image(systemName: vm.pinned ? "pin.fill" : "pin")
                    .font(.system(size: 15))
                    .foregroundColor(vm.pinned ? t.accent : t.textSecondary)
            }
            .buttonStyle(.plain)
            .help(vm.isArabic ? "تثبيت النافذة" : "Pin window")

            if vm.withScreenshot {
                Image(systemName: "photo")
                    .foregroundColor(t.textSecondary)
                    .help(vm.isArabic ? "لقطة شاشتك مرفقة مع السؤال" : "Your screenshot is attached")
            }

            Button(action: { vm.send() }) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(vm.input.isEmpty ? t.textSecondary.opacity(0.4) : t.accent)
            }
            .buttonStyle(.plain)
            .disabled(vm.input.isEmpty || vm.isLoading)
        }
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

    private var reasoningBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.system(size: 12))
                .foregroundColor(t.textSecondary)
            Text(vm.isArabic ? "التفكير:" : "Thinking:")
                .font(.system(size: 11))
                .foregroundColor(t.textSecondary)

            ForEach(ReasoningLevel.allCases, id: \.self) { lvl in
                let selected = vm.reasoning == lvl.rawValue
                Button(action: { vm.setReasoning(lvl.rawValue) }) {
                    Text(lvl.label(ar: vm.isArabic))
                        .font(.system(size: 11, weight: selected ? .bold : .regular))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(selected ? t.accent.opacity(0.28) : Color.clear)
                        )
                        .foregroundColor(selected ? t.textPrimary : t.textSecondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }
}
