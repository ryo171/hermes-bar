import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class SettingsWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 760),
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
    @Published var closeHotKey: HotKeyCombo { didSet { commit() } }
    @Published var layoutName: String { didSet { commit() } }
    @Published var iconStyle: String { didSet { commit() } }
    @Published var thinkingStyle: String { didSet { commit() } }
    @Published var thinkingSpeed: Double { didSet { commit() } }
    @Published var thinkingIntensity: Double { didSet { commit() } }
    @Published var appearanceMode: String { didSet { commit() } }
    @Published var showSuggestions: Bool { didSet { commit() } }
    @Published var serverManagedSessions: Bool { didSet { commit() } }
    @Published var directHost: String { didSet { commit() } }
    @Published var savingModel: String { didSet { commit() } }
    @Published var savingVisionModel: String { didSet { commit() } }
    @Published var deepModel: String { didSet { commit() } }
    @Published var directKey: String { didSet { commit() } }
    @Published var searchApiKey: String { didSet { commit() } }
    @Published var hiddenIcons: [String] { didSet { commit() } }
    @Published var customThemes: [CustomThemeData] { didSet { commit() } }
    @Published var savedTemplates: [SavedTemplate] { didSet { commit() } }
    @Published var removedTemplates: [String] { didSet { commit() } }

    init() {
        let s = Settings.shared
        language = s.language
        themeName = s.themeName
        host = s.host
        hotKey = s.hotKey
        newWindowHotKey = s.newWindowHotKey
        closeHotKey = s.closeHotKey
        layoutName = s.layoutName
        iconStyle = s.iconStyle
        thinkingStyle = s.thinkingStyle
        thinkingSpeed = s.thinkingSpeed
        thinkingIntensity = s.thinkingIntensity
        appearanceMode = s.appearanceMode
        showSuggestions = s.showSuggestions
        serverManagedSessions = s.serverManagedSessions
        directHost = s.directHost
        savingModel = s.savingModel
        savingVisionModel = s.savingVisionModel
        deepModel = s.deepModel
        directKey = s.directKey
        searchApiKey = s.searchApiKey
        hiddenIcons = s.hiddenIcons
        customThemes = s.customThemes
        savedTemplates = s.savedTemplates
        removedTemplates = s.removedTemplates
    }

    private func commit() {
        let s = Settings.shared
        s.language = language
        s.themeName = themeName
        s.host = host
        s.hotKey = hotKey
        s.newWindowHotKey = newWindowHotKey
        s.closeHotKey = closeHotKey
        s.layoutName = layoutName
        s.iconStyle = iconStyle
        s.thinkingStyle = thinkingStyle
        s.thinkingSpeed = thinkingSpeed
        s.thinkingIntensity = thinkingIntensity
        s.appearanceMode = appearanceMode
        s.showSuggestions = showSuggestions
        s.serverManagedSessions = serverManagedSessions
        s.directHost = directHost
        s.savingModel = savingModel
        s.savingVisionModel = savingVisionModel
        s.deepModel = deepModel
        s.directKey = directKey
        s.searchApiKey = searchApiKey
        s.hiddenIcons = hiddenIcons
        s.customThemes = customThemes
        s.savedTemplates = savedTemplates
        s.removedTemplates = removedTemplates
        s.save()
    }
}

struct SettingsView: View {
    @StateObject private var model = SettingsModel()
    @StateObject private var recorder = HotKeyRecorder()
    @State private var hasCustomIcon = HermesIcon.hasCustomImage()
    @State private var iconPreview: NSImage? = HermesIcon.loadCustomPreview()
    @State private var modelList: [String] = []
    @State private var fetchingModels = false
    @State private var draft = CustomThemeData()   // theme being designed

    private var ar: Bool { model.language == .arabic }

    private func fetchModels() {
        fetchingModels = true
        HermesClient.shared.fetchModels(host: model.directHost, apiKey: Settings.shared.resolvedDirectKey()) { ids in
            modelList = ids
            fetchingModels = false
            // Cache for the in-panel model picker.
            Settings.shared.cachedModels = ids
            Settings.shared.save()
        }
    }

    // ON = icon shown, OFF = hidden. Writes to the hidden-icons set (non-destructive).
    private func iconVisibilityBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !model.hiddenIcons.contains(id) },
            set: { show in
                var set = Set(model.hiddenIcons)
                if show { set.remove(id) } else { set.insert(id) }
                model.hiddenIcons = Array(set)
            }
        )
    }

    // A text field + a dropdown of fetched models that fills it. Type first letters
    // in the field to FILTER the dropdown (handy with 300+ models).
    @ViewBuilder private func modelField(_ binding: Binding<String>, placeholder: String) -> some View {
        let q = binding.wrappedValue.lowercased()
        let matches = q.isEmpty ? modelList : modelList.filter { $0.lowercased().contains(q) }
        let shown = Array(matches.prefix(60))
        HStack(spacing: 6) {
            TextField(placeholder, text: binding)
                .textFieldStyle(.roundedBorder)
                .frame(width: 185)
                .help(ar ? "اكتب أول حروف الموديل لتصفية القائمة" : "Type the first letters to filter the list")
            Menu {
                if modelList.isEmpty {
                    Text(ar ? "اضغط \"اجلب الموديلات\"" : "Tap \"Fetch models\"")
                } else if shown.isEmpty {
                    Text(ar ? "لا مطابقات" : "No matches")
                } else {
                    ForEach(shown, id: \.self) { m in
                        Button(m) { binding.wrappedValue = m }
                    }
                    if matches.count > shown.count {
                        Text(ar ? "…اكتب أكثر للتصفية" : "…type more to narrow")
                    }
                }
            } label: {
                Image(systemName: "chevron.down.circle")
            }
            .frame(width: 28)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").foregroundColor(.accentColor).font(.system(size: 18, weight: .semibold))
                    Text(ar ? "إعدادات Hermes Bar" : "Hermes Bar Settings")
                        .font(.system(size: 20, weight: .bold))
                }

                // General
                card(ar ? "عام" : "General") {
                    row(ar ? "اللغة" : "Language") {
                        Picker("", selection: $model.language) {
                            Text("العربية").tag(AppLanguage.arabic)
                            Text("English").tag(AppLanguage.english)
                        }
                        .labelsHidden().pickerStyle(.segmented).frame(width: 180)
                    }
                    row(ar ? "المظهر" : "Appearance") {
                        Picker("", selection: $model.appearanceMode) {
                            Text(ar ? "حسب النظام" : "System").tag("system")
                            Text(ar ? "مظلم" : "Dark").tag("dark")
                            Text(ar ? "مضيء" : "Light").tag("light")
                        }
                        .labelsHidden().pickerStyle(.segmented).frame(width: 220)
                    }
                    row(ar ? "اقتراحات المتابعة" : "Follow-up suggestions") {
                        Toggle("", isOn: $model.showSuggestions).labelsHidden().toggleStyle(.switch)
                            .help(ar ? "أسئلة متابعة مقترحة بعد كل رد (تقدر تطفّيها)."
                                     : "Suggested follow-up questions after each reply (can be turned off).")
                    }
                }

                // Appearance — theme, layout, templates, and the theme customizer.
                card(ar ? "المظهر" : "Appearance") {
                    row(ar ? "الثيم" : "Theme") {
                        Picker("", selection: $model.themeName) {
                            ForEach(Theme.selectable) { theme in Text(theme.label).tag(theme.name) }
                        }
                        .labelsHidden().frame(width: 220)
                    }
                    row(ar ? "التخطيط" : "Layout") {
                        Picker("", selection: $model.layoutName) {
                            ForEach(PanelLayout.allCases, id: \.rawValue) { l in Text(layoutLabel(l)).tag(l.rawValue) }
                        }
                        .labelsHidden().frame(width: 220)
                    }
                    row(ar ? "الأيقونة" : "Menu-bar icon") {
                        Picker("", selection: $model.iconStyle) {
                            ForEach(IconStyle.allCases, id: \.rawValue) { i in Text(iconLabel(i)).tag(i.rawValue) }
                        }
                        .labelsHidden().frame(width: 220).disabled(hasCustomIcon)
                    }
                    row(ar ? "أنميشن التفكير" : "Thinking animation") {
                        Picker("", selection: $model.thinkingStyle) {
                            ForEach(ThinkingStyle.allCases, id: \.rawValue) { s in
                                Text(ar ? s.labelAr : s.labelEn).tag(s.rawValue)
                            }
                        }
                        .labelsHidden().frame(width: 220)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        row(ar ? "سرعة الأضواء" : "Light speed") {
                            HStack(spacing: 8) {
                                Slider(value: $model.thinkingSpeed, in: 0.3...2.0).frame(width: 170)
                                Text(String(format: "%.1f×", model.thinkingSpeed)).font(.system(size: 11, design: .monospaced)).frame(width: 40)
                            }
                        }
                        row(ar ? "شدّة الأضواء" : "Light intensity") {
                            HStack(spacing: 8) {
                                Slider(value: $model.thinkingIntensity, in: 0.1...1.0).frame(width: 170)
                                Text(String(format: "%.0f%%", model.thinkingIntensity * 100)).font(.system(size: 11, design: .monospaced)).frame(width: 40)
                            }
                        }
                    }
                    row(ar ? "صورة مخصّصة" : "Custom image") { customImageControls }

                    Divider().opacity(0.4)
                    templatesSection
                    Divider().opacity(0.4)
                    themeCustomizer
                }

                // Shortcuts
                card(ar ? "الاختصارات" : "Shortcuts") {
                    hotkeyRow(ar ? "إظهار/إخفاء" : "Show/Hide", model.hotKey.displayString) { model.hotKey = $0 }
                    hotkeyRow(ar ? "محادثة جديدة" : "New conversation", model.newWindowHotKey.displayString) { model.newWindowHotKey = $0 }
                    hotkeyRow(ar ? "إغلاق المحادثة" : "Close conversation", model.closeHotKey.displayString,
                              help: ar ? "يغلق النافذة المحدّدة نهائياً" : "Destroys the focused window for good") { model.closeHotKey = $0 }
                }

                // Connection
                card(ar ? "الاتصال" : "Connection") {
                    row(ar ? "عنوان هيرميس" : "Hermes host") {
                        TextField("http://localhost:8642", text: $model.host).textFieldStyle(.roundedBorder).frame(width: 220)
                    }
                    row(ar ? "جلسات مشتركة" : "Shared sessions") {
                        Toggle("", isOn: $model.serverManagedSessions).labelsHidden().toggleStyle(.switch)
                            .help(ar ? "يخلي محادثات النافذة جلسات هيرميس حقيقية تكمّلها في الديسكتوب."
                                     : "Make panel chats real Hermes sessions you can continue in Desktop.")
                    }
                }

                // Provider & Models
                card(ar ? "المزوّد والموديلات" : "Provider & Models") {
                    row(ar ? "مزوّد التوفير" : "Direct provider") {
                        TextField("https://opencode.ai/zen/go/v1", text: $model.directHost)
                            .textFieldStyle(.roundedBorder).frame(width: 220)
                    }
                    row(ar ? "مفتاح المزوّد" : "Provider key") {
                        SecureField(ar ? "فاضي = من ~/.hermes/.env" : "empty = ~/.hermes/.env", text: $model.directKey)
                            .textFieldStyle(.roundedBorder).frame(width: 220)
                    }
                    row(ar ? "الموديلات" : "Models") {
                        Button(fetchingModels ? (ar ? "يجلب…" : "Fetching…") : (ar ? "اجلب الموديلات" : "Fetch models")) { fetchModels() }
                            .disabled(fetchingModels)
                        if !modelList.isEmpty {
                            Text(ar ? "\(modelList.count) موديل" : "\(modelList.count) models").font(.system(size: 11)).foregroundColor(.secondary)
                        }
                    }
                    row(ar ? "موديل التوفير (نصّي)" : "Saving model (text)") { modelField($model.savingModel, placeholder: "deepseek-v4-flash") }
                    row(ar ? "موديل الرؤية" : "Vision model") {
                        modelField($model.savingVisionModel, placeholder: ar ? "فاضي = نفس النصّي" : "empty = same as text")
                    }
                    row(ar ? "موديل العميق" : "Deep model") {
                        TextField(ar ? "فاضي = افتراضي هيرميس" : "empty = Hermes default", text: $model.deepModel).textFieldStyle(.roundedBorder).frame(width: 220)
                    }
                    row(ar ? "مفتاح البحث (Tavily)" : "Search key (Tavily)") {
                        SecureField(ar ? "فاضي = بحث معطّل" : "empty = no search", text: $model.searchApiKey).textFieldStyle(.roundedBorder).frame(width: 220)
                    }
                }

                // Panel icons — choose what stays on the surface; the rest go to "⋯ More".
                card(ar ? "أيقونات اللوحة" : "Panel icons") {
                    Text(ar ? "اختر اللي يظهر على الواجهة — المطفأة تنطوي تحت «⋯ المزيد» (ما يُحذف شيء)."
                            : "Choose what shows on the surface — the rest tuck under \"⋯ More\" (nothing is deleted).")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                    ForEach(PanelIcon.all) { icon in
                        HStack(spacing: 10) {
                            Image(systemName: icon.symbol).font(.system(size: 13)).frame(width: 22).foregroundColor(.secondary)
                            Text(icon.title(ar)).font(.system(size: 13))
                            Spacer()
                            Toggle("", isOn: iconVisibilityBinding(icon.id)).labelsHidden().toggleStyle(.switch)
                        }
                    }
                }

                Text(ar ? "التغييرات تُحفظ تلقائياً. تأكد أن هيرميس شغّال: hermes gateway"
                        : "Changes save automatically. Make sure Hermes is running: hermes gateway")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(width: 500, height: 760)
        .preferredColorScheme(model.appearanceMode == "dark" ? .dark : (model.appearanceMode == "light" ? .light : nil))
        .environment(\.layoutDirection, ar ? .rightToLeft : .leftToRight)
    }

    // MARK: - Section card + shared rows

    @ViewBuilder private func card<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold)).foregroundColor(.secondary).kerning(0.5)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }

    @ViewBuilder private func hotkeyRow(_ title: String, _ display: String, help: String? = nil,
                                        _ set: @escaping (HotKeyCombo) -> Void) -> some View {
        row(title) {
            HStack(spacing: 10) {
                Text(display)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.15)))
                Button(recorder.isRecording ? (ar ? "اضغط أي مفتاح…" : "Press keys…") : (ar ? "تسجيل" : "Record")) {
                    recorder.onCapture = set
                    recorder.start()
                }
                .disabled(recorder.isRecording)
                .help(help ?? "")
            }
        }
    }

    private var customImageControls: some View {
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

    // MARK: - Templates (pick a base look, then tweak)

    private var templatesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(ar ? "قوالب جاهزة" : "Templates").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(ar ? "احفظ الحالي" : "Save current") { saveCurrentTemplate() }.font(.system(size: 11))
            }
            Text(ar ? "اضغط لتطبيق قالب، أو ✕ لحذف أي قالب (حتى الجاهزة)." : "Tap to apply, ✕ to delete any template (even built-ins).")
                .font(.system(size: 11)).foregroundColor(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(visibleBuiltinTemplates) { tpl in
                        templateChipDeletable(label: tpl.title(ar), themeName: tpl.themeName, layout: tpl.layout,
                                              swatch: tpl.swatch, accent: tpl.accent,
                                              apply: { applyTemplate(tpl.themeName, tpl.layout, tpl.hidden) },
                                              delete: { model.removedTemplates.append(tpl.id) })
                    }
                    ForEach(model.savedTemplates) { st in
                        let th = Theme.byName(st.themeName)
                        templateChipDeletable(label: st.label, themeName: st.themeName, layout: st.layout,
                                              swatch: th.background, accent: th.accent,
                                              apply: { applyTemplate(st.themeName, st.layout, st.hidden) },
                                              delete: { model.savedTemplates.removeAll { $0.id == st.id } })
                    }
                }
                .padding(.vertical, 2)
            }
            if !model.savedTemplates.isEmpty {
                Text(ar ? "قوالبي (عدّل الاسم)" : "My templates (rename)").font(.system(size: 11)).foregroundColor(.secondary)
                ForEach($model.savedTemplates) { $st in
                    HStack(spacing: 8) {
                        TextField(ar ? "اسم القالب" : "Template name", text: $st.label)
                            .textFieldStyle(.roundedBorder).frame(width: 180)
                        Spacer()
                        Button(ar ? "استخدم" : "Apply") { applyTemplate(st.themeName, st.layout, st.hidden) }.font(.system(size: 11))
                        Button { model.savedTemplates.removeAll { $0.id == st.id } } label: {
                            Image(systemName: "trash").foregroundColor(.red)
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var visibleBuiltinTemplates: [DesignTemplate] {
        DesignTemplate.all.filter { !model.removedTemplates.contains($0.id) }
    }

    private func templateChipDeletable(label: String, themeName: String, layout: String,
                                       swatch: Color, accent: Color,
                                       apply: @escaping () -> Void, delete: @escaping () -> Void) -> some View {
        let selected = model.themeName == themeName && model.layoutName == layout
        return VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(swatch)
                .frame(width: 84, height: 48)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(accent, lineWidth: 2).opacity(0.9))
                .overlay(alignment: .bottomLeading) { Circle().fill(accent).frame(width: 12, height: 12).padding(6) }
                .overlay(alignment: .topTrailing) {
                    Button { delete() } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundColor(.white.opacity(0.85))
                    }.buttonStyle(.plain).padding(3)
                }
                .contentShape(Rectangle())
                .onTapGesture { apply() }
            Text(label).font(.system(size: 11)).lineLimit(1)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.accentColor.opacity(0.18) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 1.5))
    }

    private func applyTemplate(_ themeName: String, _ layout: String, _ hidden: [String]) {
        model.themeName = themeName
        model.layoutName = layout
        model.hiddenIcons = hidden
    }

    private func saveCurrentTemplate() {
        let name = (ar ? "قالبي " : "My Template ") + "\(model.savedTemplates.count + 1)"
        model.savedTemplates.append(SavedTemplate(label: name, themeName: model.themeName,
                                                  layout: model.layoutName, hidden: model.hiddenIcons))
    }

    // MARK: - Theme customizer (colours + transparency → save as a theme)

    private var themeCustomizer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ar ? "صمّم ثيمك" : "Design a theme").font(.system(size: 12, weight: .semibold))
            HStack(spacing: 10) {
                TextField(ar ? "اسم الثيم" : "Theme name", text: $draft.label).textFieldStyle(.roundedBorder).frame(width: 150)
            }
            HStack(spacing: 18) {
                colorField(ar ? "الخلفية" : "Background", r: $draft.bgR, g: $draft.bgG, b: $draft.bgB)
                colorField(ar ? "التمييز" : "Accent", r: $draft.accentR, g: $draft.accentG, b: $draft.accentB)
            }
            Toggle(ar ? "زجاجي (شفاف)" : "Glass (translucent)", isOn: $draft.glass).toggleStyle(.switch)
            if draft.glass {
                HStack(spacing: 8) {
                    Text(ar ? "الشفافية" : "Transparency").font(.system(size: 11)).frame(width: 70, alignment: .leading)
                    Slider(value: $draft.opacity, in: 0.0...0.85)
                    Text(String(format: "%.0f%%", (1 - draft.opacity) * 100)).font(.system(size: 11, design: .monospaced)).frame(width: 42)
                }
            }
            HStack {
                Button(ar ? "احفظ كثيم جديد" : "Save as theme") { saveDraftTheme() }
                    .buttonStyle(.borderedProminent)
                Spacer()
            }
            if !model.customThemes.isEmpty {
                Divider().opacity(0.4)
                Text(ar ? "ثيماتي" : "My themes").font(.system(size: 11)).foregroundColor(.secondary)
                ForEach(model.customThemes) { ct in
                    HStack(spacing: 8) {
                        Circle().fill(ct.backgroundColor).frame(width: 14, height: 14)
                            .overlay(Circle().strokeBorder(Color.secondary.opacity(0.35)))
                        Circle().fill(ct.accentColor).frame(width: 14, height: 14)
                        Text(ct.label).font(.system(size: 12)).lineLimit(1)
                        Spacer()
                        Button(ar ? "استخدم" : "Apply") { model.themeName = ct.themeName }
                            .font(.system(size: 11))
                        Button { deleteTheme(ct) } label: { Image(systemName: "trash").foregroundColor(.red) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func colorField(_ label: String, r: Binding<Double>, g: Binding<Double>, b: Binding<Double>) -> some View {
        HStack(spacing: 6) {
            ColorPicker("", selection: colorBinding(r: r, g: g, b: b), supportsOpacity: false).labelsHidden()
            Text(label).font(.system(size: 11))
        }
    }

    private func colorBinding(r: Binding<Double>, g: Binding<Double>, b: Binding<Double>) -> Binding<Color> {
        Binding(
            get: { Color(red: r.wrappedValue, green: g.wrappedValue, blue: b.wrappedValue) },
            set: { newColor in
                let ns = NSColor(newColor).usingColorSpace(.sRGB) ?? NSColor(newColor)
                r.wrappedValue = Double(ns.redComponent)
                g.wrappedValue = Double(ns.greenComponent)
                b.wrappedValue = Double(ns.blueComponent)
            }
        )
    }

    private func saveDraftTheme() {
        var t = draft
        t.id = UUID()
        if t.label.trimmingCharacters(in: .whitespaces).isEmpty { t.label = ar ? "ثيم مخصّص" : "Custom Theme" }
        model.customThemes.append(t)
        model.themeName = t.themeName            // apply the new theme immediately
        draft = CustomThemeData()                // reset the designer
    }

    private func deleteTheme(_ ct: CustomThemeData) {
        model.customThemes.removeAll { $0.id == ct.id }
        if model.themeName == ct.themeName { model.themeName = Theme.defaultTheme.name }
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
        case .aurora:  return ar ? "لوحة الشفق" : "Aurora Canvas"
        case .commandDeck: return ar ? "لوحة القيادة" : "Command Deck"
        case .palette: return ar ? "لوحة الأوامر" : "Command Palette"
        case .aiChat:  return ar ? "دردشة AI" : "AI Chat"
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

// A one-tap starting look: theme + layout + which icons stay on the surface.
struct DesignTemplate: Identifiable {
    let id: String
    let labelAr: String
    let labelEn: String
    let themeName: String
    let layout: String
    let hidden: [String]
    let swatch: Color
    let accent: Color
    func title(_ ar: Bool) -> String { ar ? labelAr : labelEn }

    static let all: [DesignTemplate] = [
        DesignTemplate(id: "graphite", labelAr: "جرافيت", labelEn: "Graphite",
                       themeName: "hb-graphite", layout: "chat", hidden: ["scrape", "spawn", "desktop"],
                       swatch: Color(red: 0.09, green: 0.09, blue: 0.11), accent: Color(red: 0.56, green: 0.64, blue: 1.0)),
        DesignTemplate(id: "glass", labelAr: "زجاجي", labelEn: "Glass",
                       themeName: "glass", layout: "classic", hidden: [],
                       swatch: Color(red: 0.16, green: 0.16, blue: 0.18), accent: Color(red: 0.42, green: 0.66, blue: 1.0)),
        DesignTemplate(id: "midnight", labelAr: "منتصف الليل", labelEn: "Midnight",
                       themeName: "midnight", layout: "rail", hidden: ["scrape", "notify"],
                       swatch: Color(red: 0.06, green: 0.07, blue: 0.15), accent: Color(red: 0.49, green: 0.55, blue: 1.0)),
        DesignTemplate(id: "mono", labelAr: "تركيز", labelEn: "Focus",
                       themeName: "mono", layout: "minimal", hidden: ["web", "scrape", "pin", "notify", "spawn", "desktop"],
                       swatch: Color(red: 0.04, green: 0.04, blue: 0.04), accent: Color(white: 0.88)),
        DesignTemplate(id: "coral", labelAr: "مرجاني", labelEn: "Coral",
                       themeName: "hb-coral", layout: "chat", hidden: ["scrape", "desktop"],
                       swatch: Color(red: 0.14, green: 0.06, blue: 0.08), accent: Color(red: 0.94, green: 0.52, blue: 0.37)),
        DesignTemplate(id: "aichat", labelAr: "دردشة AI", labelEn: "AI Chat",
                       themeName: "hb-graphite", layout: "aiChat", hidden: ["scrape", "spawn"],
                       swatch: Color(red: 0.09, green: 0.09, blue: 0.12), accent: Color(red: 0.56, green: 0.64, blue: 1.0)),
        DesignTemplate(id: "deck", labelAr: "لوحة القيادة", labelEn: "Command Deck",
                       themeName: "midnight", layout: "commandDeck", hidden: [],
                       swatch: Color(red: 0.06, green: 0.07, blue: 0.15), accent: Color(red: 0.49, green: 0.55, blue: 1.0)),
        DesignTemplate(id: "cmdpalette", labelAr: "لوحة الأوامر", labelEn: "Command Palette",
                       themeName: "hb-graphite", layout: "palette", hidden: ["spawn", "desktop"],
                       swatch: Color(red: 0.10, green: 0.10, blue: 0.13), accent: Color(red: 0.56, green: 0.64, blue: 1.0)),
    ]
}
