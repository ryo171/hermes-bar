#!/bin/bash
# One-shot installer: enables the Hermes API server, builds HermesBar, and opens it.
# Usage:  cd into this folder, then run:  bash install.sh
set -euo pipefail
cd "$(dirname "$0")"

echo "======================================"
echo "  Hermes Bar — الإعداد التلقائي"
echo "======================================"
echo

# 0) Check for the Swift toolchain (Xcode command line tools).
if ! command -v swift >/dev/null 2>&1; then
    echo "✗ أدوات البناء (Swift) غير مثبتة."
    echo "  ثبّتها بهذا الأمر ثم أعد تشغيل install.sh:"
    echo "      xcode-select --install"
    exit 1
fi

# 1) Enable the Hermes API server in ~/.hermes/.env (only adds missing lines).
HERMES_ENV="$HOME/.hermes/.env"
mkdir -p "$HOME/.hermes"
touch "$HERMES_ENV"

if ! grep -q '^API_SERVER_ENABLED=' "$HERMES_ENV"; then
    echo 'API_SERVER_ENABLED=true' >> "$HERMES_ENV"
    echo "✓ فعّلت API_SERVER_ENABLED"
else
    echo "• API_SERVER_ENABLED موجود مسبقاً — تركته كما هو"
fi

if ! grep -q '^API_SERVER_KEY=' "$HERMES_ENV"; then
    echo 'API_SERVER_KEY=change-me-local-dev' >> "$HERMES_ENV"
    echo "✓ أضفت API_SERVER_KEY"
else
    echo "• API_SERVER_KEY موجود مسبقاً — تركته كما هو"
fi

# 2) Build + package the .app bundle.
echo
echo "==> يبني التطبيق… (أول مرة ممكن تاخذ دقيقة)"
chmod +x make_app.sh
./make_app.sh

# 3) Launch it.
echo
echo "==> يفتح HermesBar.app"
open HermesBar.app

cat <<'NOTE'

======================================
  تمّ! ✅  ناقص بس ٣ أشياء منك:
======================================
  1) شغّل هيرميس (خلّ النافذة مفتوحة):
         hermes gateway

  2) أعطِ الأذونات مرة وحدة:
     System Settings ← Privacy & Security
        • Screen Recording ← فعّل HermesBar
        • Accessibility    ← فعّل HermesBar
     بعدها سكّر التطبيق وافتحه:  open HermesBar.app

  3) اضغط ⌘⇧H من أي مكان → تطلع النافذة.
======================================
NOTE
