import AppKit

// Entry point. HermesBar is a menu-bar-only app (no Dock icon), so we set the
// activation policy to .accessory and drive the run loop ourselves.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
