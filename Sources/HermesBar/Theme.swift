import SwiftUI

// Themes mirroring Hermes' own built-in dashboard themes, plus a translucent
// "Glass" theme (macOS vibrancy). Selected in Settings.
struct Theme: Identifiable {
    var id: String { name }
    let name: String          // stable id
    let label: String         // shown in the picker

    let background: Color
    let surface: Color        // input / card fill
    let accent: Color         // buttons, focus ring
    let textPrimary: Color
    let textSecondary: Color
    var isGlass: Bool = false  // when true, use a frosted NSVisualEffectView background
    var glassShade: Double = 0.16  // darkness of the dark-glass tint over the blur (0 = clear)

    static func hex(_ v: UInt32) -> Color {
        Color(
            red: Double((v >> 16) & 0xFF) / 255.0,
            green: Double((v >> 8) & 0xFF) / 255.0,
            blue: Double(v & 0xFF) / 255.0
        )
    }

    static let all: [Theme] = [
        Theme(name: "hermes-teal", label: "Hermes Teal",
              background: hex(0x0B1E1E), surface: hex(0x12312F), accent: hex(0x4FD6C2),
              textPrimary: hex(0xF3EFE0), textSecondary: hex(0x9FBDB6)),
        Theme(name: "glass", label: "Glass · زجاجي",
              background: hex(0x1A1A1F), surface: Color.white.opacity(0.10), accent: hex(0x6AA9FF),
              textPrimary: Color.white, textSecondary: Color.white.opacity(0.65), isGlass: true, glassShade: 0.14),
        // Dedicated dark-glass "command palette" look (Raycast-style): deep frosted
        // panel + strong dark tint. This is the new design as its own theme.
        Theme(name: "hb-graphite", label: "HermesBar Graphite · جرافيت",
              background: hex(0x0D0E12), surface: Color.white.opacity(0.075), accent: hex(0x8FA3FF),
              textPrimary: Color.white, textSecondary: Color.white.opacity(0.60), isGlass: true, glassShade: 0.52),
        Theme(name: "midnight", label: "Midnight",
              background: hex(0x0F1226), surface: hex(0x1B1F3B), accent: hex(0x7C8CFF),
              textPrimary: hex(0xE6E8FF), textSecondary: hex(0x9AA0CF)),
        Theme(name: "ember", label: "Ember",
              background: hex(0x1A0D0A), surface: hex(0x2E1712), accent: hex(0xE2603A),
              textPrimary: hex(0xF6E7DA), textSecondary: hex(0xC69A82)),
        Theme(name: "mono", label: "Mono",
              background: hex(0x0A0A0A), surface: hex(0x1C1C1C), accent: hex(0xE0E0E0),
              textPrimary: hex(0xF5F5F5), textSecondary: hex(0x9A9A9A)),
        Theme(name: "cyberpunk", label: "Cyberpunk",
              background: hex(0x000000), surface: hex(0x0D1A0D), accent: hex(0x39FF14),
              textPrimary: hex(0xCFFFC0), textSecondary: hex(0x5FBF4F)),
        Theme(name: "rose", label: "Rosé",
              background: hex(0x2A1620), surface: hex(0x3D2130), accent: hex(0xFF9EC4),
              textPrimary: hex(0xFDEFF4), textSecondary: hex(0xCDA3B6)),

        // HermesBar identity themes — matched to the new brand icon directions.
        Theme(name: "hb-indigo", label: "HermesBar Indigo",
              background: hex(0x14122A), surface: hex(0x211E44), accent: hex(0x8B7BF0),
              textPrimary: hex(0xECEAFB), textSecondary: hex(0xA7A2CE)),
        Theme(name: "hb-aqua", label: "HermesBar Aqua",
              background: hex(0x081F22), surface: hex(0x123338), accent: hex(0x2FC7A6),
              textPrimary: hex(0xE6F5F1), textSecondary: hex(0x8FBEB6)),
        Theme(name: "hb-coral", label: "HermesBar Coral",
              background: hex(0x241014), surface: hex(0x3A1B22), accent: hex(0xF0855E),
              textPrimary: hex(0xFAECE7), textSecondary: hex(0xCBA396)),
        Theme(name: "hb-amber", label: "HermesBar Amber",
              background: hex(0x22190A), surface: hex(0x362813), accent: hex(0xF5B84A),
              textPrimary: hex(0xF9F0DC), textSecondary: hex(0xC7B187))
    ]

    static let defaultTheme = all[0]

    static func byName(_ name: String) -> Theme {
        all.first { $0.name == name } ?? defaultTheme
    }
}
