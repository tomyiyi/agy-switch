#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="AGY Switch.app"
APP_VERSION="5.7.0"
APP_BUNDLE="$ROOT_DIR/$APP_NAME"
ICONSET="/tmp/AGYSwitch.iconset"
ICON_PNG="$ROOT_DIR/macos/icon_1024.png"

echo "1/5 生成 1024px 视网膜图标..."
swift "$ROOT_DIR/macos/make_icon.swift" "$ICON_PNG" >/dev/null
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for sz in 16 32 128 256 512; do
  sips -z $sz $sz "$ICON_PNG" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
  sz2=$((sz * 2))
  sips -z $sz2 $sz2 "$ICON_PNG" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
done

echo "2/5 组装应用包并编译模块化 SwiftUI 原生二进制 (v${APP_VERSION})..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
iconutil -c icns "$ICONSET" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cp "$ROOT_DIR/server.py" "$APP_BUNDLE/Contents/Resources/server.py"

cat > "$APP_BUNDLE/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>AgySwitch</string>
  <key>CFBundleIdentifier</key>
  <string>io.agyswitch.app</string>
  <key>CFBundleName</key>
  <string>AGY Switch</string>
  <key>CFBundleShortVersionString</key>
  <string>${APP_VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${APP_VERSION}</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
</dict>
</plist>
EOF

swiftc -O "$ROOT_DIR"/macos/Sources/*.swift -o "$APP_BUNDLE/Contents/MacOS/AgySwitch"

echo "3/5 执行 Ad-hoc 签名稳定 macOS AppleEvents 权限..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo "4/5 安装到 /Applications/$APP_NAME..."
pkill -f "AGY Switch.app/Contents/MacOS/AgySwitch" 2>/dev/null || true
rm -rf "/Applications/$APP_NAME"
cp -R "$APP_BUNDLE" "/Applications/$APP_NAME"
touch "/Applications/$APP_NAME"

echo "5/5 启动 AGY Switch v${APP_VERSION}..."
open "/Applications/$APP_NAME"
echo "✅ AGY Switch v${APP_VERSION} 构建与安装完成！"
