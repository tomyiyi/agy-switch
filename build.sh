#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="AGY Switch.app"
APP_BUNDLE="$ROOT_DIR/$APP_NAME"
ICONSET="/tmp/AGYSwitch.iconset"
ICON_PNG="$ROOT_DIR/macos/icon_1024.png"

echo "1/4 生成视网膜图标..."
swift "$ROOT_DIR/macos/make_icon.swift" >/dev/null
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for sz in 16 32 128 256 512; do
  sips -z $sz $sz "$ICON_PNG" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
  sz2=$((sz * 2))
  sips -z $sz2 $sz2 "$ICON_PNG" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
done

echo "2/4 组装应用包与编译 SwiftUI 原生二进制..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
iconutil -c icns "$ICONSET" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

cat > "$APP_BUNDLE/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>AgySwitch</string>
  <key>CFBundleIdentifier</key>
  <string>com.tom.agyswitch</string>
  <key>CFBundleName</key>
  <string>AGY Switch</string>
  <key>CFBundleVersion</key>
  <string>1.5.0</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
</dict>
</plist>
EOF

swiftc -O "$ROOT_DIR/macos/AgySwitch.swift" -o "$APP_BUNDLE/Contents/MacOS/AgySwitch"

echo "3/4 安装到 /Applications/$APP_NAME..."
pkill -f "AGY Switch.app/Contents/MacOS/AgySwitch" 2>/dev/null || true
rm -rf "/Applications/$APP_NAME"
cp -R "$APP_BUNDLE" "/Applications/$APP_NAME"
touch "/Applications/$APP_NAME"

echo "4/4 启动 AGY Switch..."
open "/Applications/$APP_NAME"
echo "✅ 构建与安装完成！"
