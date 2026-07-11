<div align="center">

# HermesBar

**A fast, native macOS menu-bar companion for [Hermes Agent](https://github.com/NousResearch/hermes-agent).**
Summon a floating, Spotlight-style panel from anywhere, ask about what's on your screen, and let Hermes act — with rich Markdown answers, themes, and full Arabic / RTL support.

نافذة عائمة سريعة تخلّي هيرميس حاضر معك في أي مكان — تناديه باختصار، يشوف شاشتك، ويرد بتنسيق غني.

[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-black?logo=apple)](#)
[![Swift](https://img.shields.io/badge/Swift-5.9-orange?logo=swift)](#)
[![Build](https://img.shields.io/badge/build-GitHub%20Actions-2088FF?logo=githubactions&logoColor=white)](#)
[![License](https://img.shields.io/badge/license-MIT-green)](#license)

<!-- Add a screenshot or GIF here — it makes the biggest difference:
<img src="docs/demo.png" width="640" alt="HermesBar demo">
-->

</div>

---

## ✨ Why HermesBar

Hermes Agent is powerful, but it lives in a terminal. **HermesBar puts it one keystroke away** — a lightweight native panel that floats over everything, sees your screen when you want, and talks to your local Hermes gateway.

- 🪶 **Native & light** — pure Swift + AppKit/SwiftUI. No Electron, no WebView.
- ⌨️ **Global hotkey** — summon it anywhere, Spotlight-style. Click away and it vanishes.
- 👁️ **Screen vision** — attach a screenshot with one tap so Hermes sees your problem.
- 🧩 **Rich Markdown** — real tables, styled code blocks with per-block copy, checklists.
- 🌍 **Arabic-first** — full RTL, with an English mode too.

## 🎯 Features

| | |
|---|---|
| **Floating panel** | Borderless, resizable, always-on-top. Remembers its size. |
| **Global hotkey** | Configurable (default ⌘⇧H). Toggle from anywhere. |
| **Screen vision (👁️)** | Attach a live screenshot — turn off for faster text-only asks. |
| **Attachments** | Pick or **drag-and-drop** files, images, and folders. |
| **Fast ↔ Quality** | One switch trades reasoning depth for speed. |
| **3-state pin** | Off (Spotlight) · Here (stays in place) · Everywhere (follows you). |
| **Notify when done (🔔)** | Fire off a task, walk away, get a notification. |
| **Rich answers** | Markdown tables, fenced code blocks + copy button, task checklists. |
| **Answer actions** | Copy all · Copy code · Regenerate. Selectable text. |
| **Response timer** | See exactly how long each answer took — compare models. |
| **Themes** | 6 themes + a translucent **Glass** (macOS vibrancy) mode. |
| **Open Hermes Desktop** | Jump to the full app for heavy, context-rich conversations. |
| **Quick read (🔎)** | One-tap prompt starter for fast page reading. |

## 📦 Requirements

- **macOS 13+**
- **[Hermes Agent](https://github.com/NousResearch/hermes-agent)** installed, with its API server enabled:
  ```bash
  # ~/.hermes/.env
  API_SERVER_ENABLED=true
  API_SERVER_KEY=change-me-local-dev
  ```
  Then run the gateway and keep it open:
  ```bash
  hermes gateway
  ```

## 🚀 Install

### Option A — Download a build (recommended)

Every push is built on a cloud Mac via GitHub Actions. Grab the latest `HermesBar-app` artifact from the [**Actions**](../../actions) tab, unzip it, then:

```bash
xattr -dr com.apple.quarantine ~/Downloads/HermesBar.app
open ~/Downloads/HermesBar.app
```

### Option B — Build from source

Requires the Xcode command-line tools (`xcode-select --install`).

```bash
git clone https://github.com/ryo171/hermes-bar.git
cd hermes-bar
./make_app.sh          # builds and packages HermesBar.app
open HermesBar.app
```

On first launch, grant **Screen Recording** and **Accessibility** in
System Settings → Privacy & Security (needed for the screenshot and the global hotkey).

## ⌨️ Usage

- Press **⌘⇧H** anywhere → the panel appears.
- Type your question (**Enter** sends, **Shift+Enter** for a new line).
- Toggle **👁️** to include your screen, **🔔** to be notified when a long task finishes.
- Open **Settings** from the menu-bar icon to pick your hotkey, theme, and language.

## 🧭 Architecture

```
┌──────────────┐    OpenAI-compatible     ┌──────────────────┐
│  HermesBar   │  ── /v1/chat/completions ─▶│  Hermes gateway  │
│ (Swift panel)│  ◀── streaming (SSE) ──────│  localhost:8642  │
└──────────────┘                            └──────────────────┘
   hotkey · vision · Markdown UI               your model + 30+ tools
```

HermesBar is a thin, native client. All intelligence and tools (terminal, files,
browser, computer-use, web) come from your local Hermes agent.

## 🗺️ Roadmap

- [ ] Conversation history + memory (with Obsidian archive)
- [ ] Collapsible `<details>` sections in answers
- [ ] Web change-monitor skill (notify on Telegram)
- [ ] Multiple UI designs per theme

## 🤝 Contributing

Issues and PRs are welcome. Open an issue to discuss a feature before sending a large change.

## 📄 License

MIT © ryo171 — see [LICENSE](LICENSE).
