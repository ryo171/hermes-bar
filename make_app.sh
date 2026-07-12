#!/bin/bash
# Builds HermesBar and wraps it into a proper macOS .app bundle.
# A bundle matters because macOS attaches the Accessibility (hotkey) and
# Screen Recording permissions to the .app identity — not to your terminal.
set -euo pipefail

cd "$(dirname "$0")"

echo "==> Building release binary…"
swift build -c release

BIN=".build/release/HermesBar"
APP="HermesBar.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"

echo "==> Assembling $APP …"
rm -rf "$APP"
mkdir -p "$MACOS" "$RES"
cp "$BIN" "$MACOS/HermesBar"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>Hermes Bar</string>
    <key>CFBundleDisplayName</key>     <string>Hermes Bar</string>
    <key>CFBundleIdentifier</key>      <string>com.local.hermesbar</string>
    <key>CFBundleVersion</key>         <string>1.0</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleExecutable</key>      <string>HermesBar</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <!-- Menu-bar only, no Dock icon -->
    <key>LSUIElement</key>             <true/>
    <!-- Screen Recording prompt copy -->
    <key>NSScreenCaptureUsageDescription</key>
    <string>Hermes Bar takes a screenshot so Hermes can see what you need help with.</string>
</dict>
</plist>
PLIST

# Optional: drop your real logo at ./hermes-menubar.png before running to bundle it.
if [ -f "hermes-menubar.png" ]; then
    cp "hermes-menubar.png" "$RES/hermes-menubar.png"
    echo "==> Bundled custom menu-bar icon."
fi

# The shipped "Hermes" icon style (selectable in Settings).
if [ -f "hermes-girl.png" ]; then
    cp "hermes-girl.png" "$RES/hermes-girl.png"
    echo "==> Bundled Hermes icon style."
fi

# Ad-hoc codesign so the permission grants stick across launches.
codesign --force --deep --sign - "$APP" 2>/dev/null || \
    echo "   (codesign skipped — app still runs; you may re-grant permissions after rebuilds)"

echo "==> Done: $APP"
echo "    Run it:   open $APP"
echo "    Autostart: System Settings → General → Login Items → add HermesBar.app"
