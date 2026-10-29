#!/bin/zsh
# Собирает «Пульс» и кладёт в /Applications/Pulse.app. Запуск: ./build.sh
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP="/Applications/Pulse.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -f Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -f .build/release/MacPulse "$APP/Contents/MacOS/MacPulse"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.pulse.app</string>
    <key>CFBundleName</key><string>Пульс</string>
    <key>CFBundleDisplayName</key><string>Пульс</string>
    <key>CFBundleExecutable</key><string>MacPulse</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
touch "$APP"
echo "Готово: $APP"
