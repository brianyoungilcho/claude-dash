#!/usr/bin/env bash
set -euo pipefail

# Build Claude Dash into /Applications/Claude Dash.app (universal binary)
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="/Applications/Claude Dash.app"
BIN_NAME="ClaudeDash"
BUILD="$ROOT/.build"
VERSION="${CLAUDE_DASH_VERSION:-1.5.7}"

echo "==> Compiling (arm64 + x86_64)"
rm -rf "$BUILD"
mkdir -p "$BUILD"
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 \
    -target "${arch}-apple-macos13.0" \
    -o "$BUILD/$BIN_NAME-$arch" \
    "$ROOT"/Sources/*.swift \
    -framework AppKit -framework SwiftUI -framework Security -framework ServiceManagement -framework WebKit -framework Carbon -framework UserNotifications
done
lipo -create -output "$BUILD/$BIN_NAME" "$BUILD/$BIN_NAME-arm64" "$BUILD/$BIN_NAME-x86_64"

echo "==> Assembling app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/$BIN_NAME" "$APP/Contents/MacOS/$BIN_NAME"
cp "$ROOT/Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Claude Dash</string>
  <key>CFBundleDisplayName</key><string>Claude Dash</string>
  <key>CFBundleIdentifier</key><string>com.claudedash.app</string>
  <key>CFBundleExecutable</key><string>ClaudeDash</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST

echo "==> Ad-hoc signing"
codesign --force --deep --sign - "$APP"

echo "==> Done: $APP (v${VERSION}, $(lipo -archs "$APP/Contents/MacOS/$BIN_NAME"))"
