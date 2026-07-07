import AppKit
import SwiftUI
import Combine

// Panel width. Bumped wider so long RTL replies aren't cramped.
let kPanelWidth: CGFloat = 680

// MARK: - Borderless floating panel (the Cowork-style window)

final class FloatingPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - View model shared between AppKit and SwiftUI

final class AskViewModel: ObservableObject {
    @Published var input: String = ""
    @Published var response: String = ""
    @Published var errorText: String = ""
    @Published var isLoading: Bool = false
    @Published var withScreenshot: Bool = true
    @Published var pinned: Bool = false     // when true, window stays until hotkey pressed again

    @Published var theme: Theme = Settings.shared.theme
    @Published var isArabic: Bool = Settings.shared.language == .arabic

    var onClose: (() -> Void)?

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
        // note: `pinned` is intentionally NOT reset, so the preference sticks.
        refreshFromSettings()
    }

    func send() {
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isLoading else { return }
        isLoading = true
        errorText = ""
        response = ""

        let wantsShot = withScreenshot
        DispatchQueue.global(qos: .userInitiated).async {
            let shot = wantsShot ? Screenshot.captureBase64PNG() : nil
            HermesClient.shared.ask(question: question, screenshotBase64: shot) { [weak self] result in
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

// MARK: - Panel controller

final class AskPanelController: NSObject, NSWindowDelegate {
    private var panel: FloatingPanel?
    private let viewModel = AskViewModel()
    private var cancellables = Set<AnyCancellable>()
    private var anchorTopY: CGFloat = 0

    var isVisible: Bool { panel?.isVisible ?? false }

    func present(withScreenshot: Bool) {
        viewModel.reset(withScreenshot: withScreenshot)
        viewModel.onClose = { [weak self] in self?.dismiss() }

        if panel == nil {
            let rect = NSRect(x: 0, y: 0, width: kPanelWidth, height: 68)
            let p = FloatingPanel(contentRect: rect)
            p.contentViewController = NSHostingController(rootView: AskView(vm: viewModel))
            p.delegate = self
            panel = p

            viewModel.objectWillChange
                .sink { [weak self] in
                    DispatchQueue.main.async { self?.repositionKeepingTop() }
                }
                .store(in: &cancellables)
        }

        computeAnchor()
        repositionKeepingTop()
        NSApp.activate(ignoringOtherApps: true)
        panel!.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        panel?.orderOut(nil)
    }

    func applyTheme() {
        viewModel.refreshFromSettings()
    }

    // Click-away to close: when the panel loses focus and isn't pinned, hide it.
    func windowDidResignKey(_ notification: Notification) {
        if !viewModel.pinned {
            DispatchQueue.main.async { [weak self] in self?.dismiss() }
        }
    }

    private func computeAnchor() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        anchorTopY = visible.maxY - visible.height * 0.16
    }

    private func repositionKeepingTop() {
        guard let panel = panel else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let x = visible.midX - size.width / 2
        let y = anchorTopY - size.height
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - SwiftUI content

struct AskView: View {
    @ObservedObject var vm: AskViewModel
    @FocusState private var inputFocused: Bool

    private var t: Theme { vm.theme }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            inputRow
            if vm.isLoading { loadingRow }
            if !vm.errorText.isEmpty { errorRow }
            if !vm.response.isEmpty { responseRow }
        }
        .padding(16)
        .frame(width: kPanelWidth, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(t.background)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(t.accent.opacity(0.25), lineWidth: 1)
                )
        )
        .environment(\.layoutDirection, vm.isArabic ? .rightToLeft : .leftToRight)
        .onAppear { inputFocused = true }
        .onExitCommand { vm.onClose?() }
    }

    private var placeholder: String {
        vm.isArabic ? "وش تحتاج مساعدة فيه؟" : "What do you need help with?"
    }

    private var inputRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundColor(t.accent)
                .font(.system(size: 16, weight: .semibold))

            TextField(placeholder, text: $vm.input)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .foregroundColor(t.textPrimary)
                .focused($inputFocused)
                .onSubmit { vm.send() }

            Button(action: { vm.pinned.toggle() }) {
                Image(systemName: vm.pinned ? "pin.fill" : "pin")
                    .font(.system(size: 14))
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
                    .font(.system(size: 22))
                    .foregroundColor(vm.input.isEmpty ? t.textSecondary.opacity(0.4) : t.accent)
            }
            .buttonStyle(.plain)
            .disabled(vm.input.isEmpty || vm.isLoading)
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(vm.isArabic ? "هيرميس يفكّر…" : "Hermes is thinking…")
                .font(.system(size: 13))
                .foregroundColor(t.textSecondary)
        }
    }

    private var errorRow: some View {
        Text(vm.errorText)
            .font(.system(size: 13))
            .foregroundColor(.red)
            .textSelection(.enabled)
    }

    private var responseRow: some View {
        ScrollView {
            Text(vm.response)
                .font(.system(size: 14))
                .foregroundColor(t.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(12)
        }
        .frame(maxHeight: 360)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(t.surface)
        )
    }
}
