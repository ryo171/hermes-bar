import AppKit
import Carbon.HIToolbox

// User-configurable settings, persisted as JSON at ~/.hermes/hermes-bar.json so
// it lives right next to your Hermes config.

enum AppLanguage: String, Codable, CaseIterable {
    case arabic
    case english
}

struct HotKeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var cmd: Bool
    var shift: Bool
    var option: Bool
    var control: Bool

    static let `default` = HotKeyCombo(keyCode: UInt32(kVK_ANSI_H),
                                       cmd: true, shift: true, option: false, control: false)

    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if cmd { m |= UInt32(cmdKey) }
        if shift { m |= UInt32(shiftKey) }
        if option { m |= UInt32(optionKey) }
        if control { m |= UInt32(controlKey) }
        return m
    }

    // Human-readable label, e.g. "⌘⇧H".
    var displayString: String {
        var s = ""
        if control { s += "⌃" }
        if option { s += "⌥" }
        if shift { s += "⇧" }
        if cmd { s += "⌘" }
        s += KeyNames.name(for: keyCode)
        return s
    }
}

final class Settings: Codable {
    static let shared = Settings.load()
    static let didChangeNotification = Notification.Name("HermesBarSettingsDidChange")

    var language: AppLanguage = .arabic
    var themeName: String = Theme.defaultTheme.name
    var hotKey: HotKeyCombo = .default
    var newWindowHotKey: HotKeyCombo = HotKeyCombo(keyCode: UInt32(kVK_ANSI_N),
                                                   cmd: true, shift: true, option: false, control: false)
    var closeHotKey: HotKeyCombo = HotKeyCombo(keyCode: UInt32(kVK_ANSI_W),
                                               cmd: true, shift: false, option: true, control: false)
    var layoutName: String = "classic"
    var iconStyle: String = "winged"
    var thinkingStyle: String = "topWash"   // how the "thinking" animation looks
    var serverManagedSessions: Bool = true   // use X-Hermes-Session-Id (Hermes holds history)

    // Saving mode: talk directly to a cheap model (no Hermes agent overhead).
    var directHost: String = "https://opencode.ai/zen/go/v1"   // any OpenAI-compatible base
    var savingModel: String = "deepseek-v4-flash"              // fast daily text model
    var savingVisionModel: String = ""                         // for screenshots; empty → savingModel
    var deepModel: String = ""               // empty → "hermes-agent" (Hermes decides)
    var directKey: String = ""               // direct-provider key; empty → ~/.hermes/.env
    var searchApiKey: String = ""            // Tavily key → web search works with ANY provider

    var host: String = "http://localhost:8642"
    var apiKey: String = ""     // empty → resolved from ~/.hermes/.env at request time
    var captureFullScreen: Bool = true

    // Non-destructive icon manager: ids of control-row icons the user moved OFF the
    // surface. They aren't deleted — they live under the panel's "⋯ More" popover
    // and can be brought back to the surface anytime. See PanelIcon.all.
    var hiddenIcons: [String] = []

    // User-made themes (color + transparency), editable in Settings.
    var customThemes: [CustomThemeData] = []

    // Last-fetched provider model ids — cached so the in-panel model picker works
    // without re-fetching every time.
    var cachedModels: [String] = []

    var theme: Theme { Theme.byName(themeName) }

    func isIconHidden(_ id: String) -> Bool { hiddenIcons.contains(id) }
    func setIcon(_ id: String, hidden: Bool) {
        var set = Set(hiddenIcons)
        if hidden { set.insert(id) } else { set.remove(id) }
        hiddenIcons = Array(set)
    }

    // MARK: - Persistence

    static var hermesDir: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".hermes")
    }
    private static var fileURL: URL {
        URL(fileURLWithPath: hermesDir).appendingPathComponent("hermes-bar.json")
    }

    private enum CodingKeys: String, CodingKey {
        case language, themeName, hotKey, newWindowHotKey, closeHotKey, layoutName, iconStyle, thinkingStyle, serverManagedSessions
        case directHost, savingModel, savingVisionModel, deepModel, directKey, searchApiKey
        case host, apiKey, captureFullScreen, hiddenIcons, customThemes, cachedModels
    }

    init() {}

    // Decode key-by-key so older config files (missing the newer fields) still
    // load — a missing key falls back to its default instead of wiping settings.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        language = try c.decodeIfPresent(AppLanguage.self, forKey: .language) ?? .arabic
        themeName = try c.decodeIfPresent(String.self, forKey: .themeName) ?? Theme.defaultTheme.name
        hotKey = try c.decodeIfPresent(HotKeyCombo.self, forKey: .hotKey) ?? .default
        newWindowHotKey = try c.decodeIfPresent(HotKeyCombo.self, forKey: .newWindowHotKey)
            ?? HotKeyCombo(keyCode: UInt32(kVK_ANSI_N), cmd: true, shift: true, option: false, control: false)
        closeHotKey = try c.decodeIfPresent(HotKeyCombo.self, forKey: .closeHotKey)
            ?? HotKeyCombo(keyCode: UInt32(kVK_ANSI_W), cmd: true, shift: false, option: true, control: false)
        layoutName = try c.decodeIfPresent(String.self, forKey: .layoutName) ?? "classic"
        iconStyle = try c.decodeIfPresent(String.self, forKey: .iconStyle) ?? "winged"
        thinkingStyle = try c.decodeIfPresent(String.self, forKey: .thinkingStyle) ?? "topWash"
        serverManagedSessions = try c.decodeIfPresent(Bool.self, forKey: .serverManagedSessions) ?? true
        directHost = try c.decodeIfPresent(String.self, forKey: .directHost) ?? "https://opencode.ai/zen/go/v1"
        savingModel = try c.decodeIfPresent(String.self, forKey: .savingModel) ?? "deepseek-v4-flash"
        savingVisionModel = try c.decodeIfPresent(String.self, forKey: .savingVisionModel) ?? ""
        deepModel = try c.decodeIfPresent(String.self, forKey: .deepModel) ?? ""
        directKey = try c.decodeIfPresent(String.self, forKey: .directKey) ?? ""
        searchApiKey = try c.decodeIfPresent(String.self, forKey: .searchApiKey) ?? ""
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? "http://localhost:8642"
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        captureFullScreen = try c.decodeIfPresent(Bool.self, forKey: .captureFullScreen) ?? true
        hiddenIcons = try c.decodeIfPresent([String].self, forKey: .hiddenIcons) ?? []
        customThemes = try c.decodeIfPresent([CustomThemeData].self, forKey: .customThemes) ?? []
        cachedModels = try c.decodeIfPresent([String].self, forKey: .cachedModels) ?? []
    }

    static func load() -> Settings {
        guard let data = try? Data(contentsOf: fileURL),
              let s = try? JSONDecoder().decode(Settings.self, from: data)
        else { return Settings() }
        return s
    }

    func save() {
        try? FileManager.default.createDirectory(
            atPath: Settings.hermesDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: Settings.fileURL)
        }
        NotificationCenter.default.post(name: Settings.didChangeNotification, object: nil)
    }

    // Resolve the API key: explicit setting wins, else read ~/.hermes/.env,
    // else fall back to Hermes' documented local-dev default.
    func resolvedAPIKey() -> String {
        if !apiKey.isEmpty { return apiKey }
        return envValue(forKeys: ["API_SERVER_KEY"]) ?? "change-me-local-dev"
    }

    // The key for Saving (direct) mode: explicit setting wins, else ~/.hermes/.env.
    func resolvedDirectKey() -> String {
        if !directKey.isEmpty { return directKey }
        return envValue(forKeys: ["OPENCODE_API_KEY", "OPENROUTER_API_KEY", "OPENROUTER_KEY"]) ?? ""
    }

    private func envValue(forKeys keys: [String]) -> String? {
        let envPath = (Settings.hermesDir as NSString).appendingPathComponent(".env")
        guard let text = try? String(contentsOfFile: envPath, encoding: .utf8) else { return nil }
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            for key in keys where line.hasPrefix(key + "=") {
                return String(line.dropFirst(key.count + 1))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            }
        }
        return nil
    }
}
