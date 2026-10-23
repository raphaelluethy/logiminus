#!/bin/bash
# Builds Logiminus.app (menu bar agent + CLI in one binary), signs it and
# optionally installs it to ~/Applications with a `logiminus` CLI symlink.
#   scripts/build-app.sh            build into ./build
#   scripts/build-app.sh --install  build, install, link CLI into ~/.local/bin
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
APP=build/Logiminus.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/logiminus "$APP/Contents/MacOS/logiminus"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>gg.lty.logiminus</string>
  <key>CFBundleName</key><string>Logiminus</string>
  <key>CFBundleExecutable</key><string>logiminus</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSHumanReadableCopyright</key><string>Raphael Lüthy</string>
</dict>
</plist>
PLIST

# A stable signing identity keeps the Accessibility grant across rebuilds;
# falls back to ad-hoc signing (re-grant needed after each rebuild).
IDENTITY="${LOGIMINUS_SIGN_IDENTITY:-$(security find-identity -p codesigning -v | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}"
codesign --force --sign "${IDENTITY:--}" --options runtime "$APP"
echo "built $APP (signed with ${IDENTITY:-ad-hoc})"

if [[ "${1:-}" == "--install" ]]; then
  "$HOME/Applications/Logiminus.app/Contents/MacOS/logiminus" quit >/dev/null 2>&1 || true
  for _ in {1..50}; do pgrep -qf "Logiminus.app/Contents/MacOS/logiminus" || break; sleep 0.1; done
  mkdir -p "$HOME/Applications" "$HOME/.local/bin"
  rm -rf "$HOME/Applications/Logiminus.app"
  cp -R "$APP" "$HOME/Applications/"
  ln -sf "$HOME/Applications/Logiminus.app/Contents/MacOS/logiminus" "$HOME/.local/bin/logiminus"
  open -g "$HOME/Applications/Logiminus.app"
  echo "installed ~/Applications/Logiminus.app, CLI at ~/.local/bin/logiminus"
fi
