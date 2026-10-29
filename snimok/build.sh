#!/bin/zsh
# Собирает «Снимок» и кладёт в /Applications/Snimok.app. Запуск: ./build.sh
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP="/Applications/Snimok.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -f Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -f .build/release/Snimok "$APP/Contents/MacOS/Snimok"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.snimok.app</string>
    <key>CFBundleName</key><string>Снимок</string>
    <key>CFBundleDisplayName</key><string>Снимок</string>
    <key>CFBundleExecutable</key><string>Snimok</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>Чтобы записывать ваш голос в видео с экрана, если вы включите «Микрофон».</string>
</dict>
</plist>
PLIST
# Правило «это local.snimok.app»: macOS узнаёт программу по имени, и разрешение на запись экрана не слетает после обновлений.
codesign --force --sign - -r='designated => identifier "local.snimok.app"' "$APP"
touch "$APP"
echo "Готово: $APP"
