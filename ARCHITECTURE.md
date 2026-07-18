# HermesBar — Architecture & Editing Guide

A native **macOS menu-bar app** (Swift + AppKit + SwiftUI, Swift Package Manager,
macOS 13+) that puts a floating Spotlight-style panel one keystroke away, talking to
a local **Hermes Agent** gateway via the OpenAI-compatible `/v1/chat/completions` API.
Arabic-first, RTL. Built in CI via GitHub Actions (macos-14) → produces `HermesBar.app`.

> If you are an AI model asked to edit the design/UI: **almost everything visual lives
> in `Sources/HermesBar/AskPanel.swift`.** Start there. Keep changes compiling — the
> only build is GitHub Actions, so a single Swift error turns the whole build red.

## Build
- `swift build -c release` (or the CI does it). Packaging: `make_app.sh` → `HermesBar.app`.
- Dependencies (SPM): `swift-markdown-ui` (MarkdownUI), `NetworkImage`, `swift-cmark`.
- Entry point: `Sources/HermesBar/main.swift` → `AppDelegate`.

## Files (Sources/HermesBar/)
| File | Lines | What it holds |
|---|---|---|
| **AskPanel.swift** | ~2400 | **The whole floating panel UI.** Layouts, message rendering, composer, control icons, thinking animations, Kanban overlay, the `AskViewModel` (send/stream/queue/suggestions), and the `AskPanelController` (NSPanel window). **Edit design here.** |
| **Theme.swift** | ~120 | `Theme` (colors), built-in themes, `CustomThemeData` (user themes), `SavedTemplate`. |
| **SettingsWindow.swift** | ~650 | The Settings window (cards): language, appearance mode, theme picker + customizer, templates, shortcuts, provider/models, panel-icon manager. |
| **Settings.swift** | ~190 | Persisted settings model (`~/.hermes/hermes-bar.json`), Codable. Add new prefs here (field + CodingKeys + `init(from:)`). |
| **HermesClient.swift** | ~240 | Networking: SSE streaming `askStream`, `fetchModels`, Tavily `webSearchBlocking`, session titling. |
| **AppDelegate.swift** | ~280 | Menu-bar item, global hotkeys, the strict window model (`windows` array; New-conversation creates, Show/Hide toggles, Close destroys). |
| **GlobalHotKey.swift** | ~125 | Carbon global hotkey registration (single shared dispatcher). |
| **HermesIcon.swift** | ~230 | Menu-bar icon styles + custom image. |
| **Screenshot.swift** | ~47 | Screen capture → base64 for vision. |

## Key concepts in AskPanel.swift
- **`PanelLayout` enum** — the selectable layouts: `classic, chat, rail, minimal, aurora,
  commandDeck, palette, aiChat`. Each has a `xxxLayout` computed view. **To add a new
  design: add an enum case, a `case` in `layoutBody`, a `xxxLayout` view, and a case in
  `SettingsWindow.layoutLabel`.**
- **`AskView.body`** — root ZStack: `baseBackground` + `auroraOrThinkingLayer` (living
  lights) + `layoutBody`. Appearance via `.preferredColorScheme(colorSchemeForMode)`.
- **Message rendering** — `messageView(_:)` → `assistantBody(_:)` splits the reply into
  prose (`SelectableAttributedText`, native selectable, clean copy, RTL-aware) and code
  blocks (`codeBlockView`, rectangle + copy button).
- **Control icons** — `PanelIcon.all` catalog; `controlIcon(id)`/`triggerIcon(id)`;
  hidden icons go under the `⋯ More` menu. The icon manager toggles are in Settings.
- **Thinking animations** — `ThinkingStyle` enum (topWash / radialAurora / pulseDots /
  statusLine / off) + `ThinkingWash`, `RadialAurora`, `PulseDots`, `StatusCycler`.
  Controlled by `Settings.thinkingStyle/thinkingSpeed/thinkingIntensity`.
- **Kanban** — local `KanbanStore` (UserDefaults) + `kanbanOverlay`/`kanbanColumn`.
- **Themes/Templates** — `Theme.selectable` (built-in + custom). Templates in
  `SettingsWindow.DesignTemplate.all` + user `SavedTemplate`s.

## Guardrails when editing
- SwiftUI `@ViewBuilder` blocks support **max 10 direct children** — group extras in a
  sub-`VStack` if you exceed it.
- Every `switch` over `PanelLayout`/`ThinkingStyle` must stay **exhaustive**.
- New persisted setting → add to `Settings.swift` (property + `CodingKeys` +
  `init(from:)` default) **and** the `SettingsModel` in `SettingsWindow.swift`.
- Keep RTL: Arabic prose should right-align; code blocks force `.leftToRight`.
- Test mentally that it compiles — CI is the only build.

## How the panel talks to Hermes
`HermesClient.askStream(host:conversation:model:...)` → `POST {host}/v1/chat/completions`
with SSE streaming. Saving mode uses a cheap direct provider (OpenCode Go); Deep mode
uses the Hermes gateway (`localhost:8642`) with `X-Hermes-Session-Id`.
