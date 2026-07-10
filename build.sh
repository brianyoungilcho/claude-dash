#!/usr/bin/env bash
set -euo pipefail

# Build Claude Dash into /Applications/Claude Dash.app (universal binary).
# CLAUDE_DASH_APP_PATH can point at a disposable bundle for CI/RC testing.
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="${CLAUDE_DASH_APP_PATH:-/Applications/Claude Dash.app}"
BIN_NAME="ClaudeDash"
BUILD="$ROOT/.build"
VERSION="${CLAUDE_DASH_VERSION:-1.6.0}"
BUILD_VERSION="${CLAUDE_DASH_BUILD_VERSION:-$VERSION}"
SPARKLE_ROOT="$ROOT/Vendor/Sparkle"
SPARKLE_FRAMEWORK="$SPARKLE_ROOT/Sparkle.framework"
DEFAULT_SPARKLE_FEED_URL="https://brianyoungilcho.github.io/claude-dash/appcast.xml"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$ ]]; then
  echo "CLAUDE_DASH_VERSION must be MAJOR.MINOR.PATCH or MAJOR.MINOR.PATCH-rc.N." >&2
  exit 1
fi
if [[ ! "$BUILD_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
  echo "CLAUDE_DASH_BUILD_VERSION must contain one to three numeric components." >&2
  exit 1
fi

"$ROOT/Scripts/bootstrap-sparkle.sh"

# The Ed25519 public key is intentionally not invented or committed before the
# release owner generates it. A local source build stays fully usable with the
# existing GitHub Releases checker until this value is supplied. CI release
# builds set SPARKLE_PUBLIC_ED_KEY from a public Actions variable.
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-}"
if [[ -z "$SPARKLE_PUBLIC_ED_KEY" && -f "$ROOT/Config/SparklePublicKey.txt" ]]; then
  SPARKLE_PUBLIC_ED_KEY="$(tr -d '\r\n' < "$ROOT/Config/SparklePublicKey.txt")"
fi
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-$DEFAULT_SPARKLE_FEED_URL}"
SPARKLE_ENABLED=0
if [[ -n "$SPARKLE_PUBLIC_ED_KEY" ]]; then
  if [[ "$SPARKLE_PUBLIC_ED_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] \
    && printf '%s' "$SPARKLE_FEED_URL" | LC_ALL=C grep -Eq '^https://[^[:space:]<>&"]+$'; then
    SPARKLE_ENABLED=1
  else
    echo "Sparkle public key or feed URL is malformed; refusing to enable in-app updates." >&2
  fi
fi
if [[ "${CLAUDE_DASH_REQUIRE_SPARKLE:-0}" == "1" && "$SPARKLE_ENABLED" != "1" ]]; then
  echo "CLAUDE_DASH_REQUIRE_SPARKLE=1 requires a valid SPARKLE_PUBLIC_ED_KEY and HTTPS SPARKLE_FEED_URL." >&2
  exit 1
fi

echo "==> Compiling (arm64 + x86_64)"
rm -rf "$BUILD"
mkdir -p "$BUILD"
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 \
    -target "${arch}-apple-macos13.0" \
    -o "$BUILD/$BIN_NAME-$arch" \
    "$ROOT"/Sources/*.swift \
    -F "$SPARKLE_ROOT" -framework Sparkle \
    -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
    -framework AppKit -framework SwiftUI -framework Security -framework ServiceManagement -framework WebKit -framework Carbon -framework UserNotifications
done
lipo -create -output "$BUILD/$BIN_NAME" "$BUILD/$BIN_NAME-arm64" "$BUILD/$BIN_NAME-x86_64"

echo "==> Assembling app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BUILD/$BIN_NAME" "$APP/Contents/MacOS/$BIN_NAME"
cp "$ROOT/Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$SPARKLE_ROOT/LICENSE" "$APP/Contents/Resources/Sparkle-LICENSE.txt"
ditto "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"

SPARKLE_PLIST=""
if [[ "$SPARKLE_ENABLED" == "1" ]]; then
  SPARKLE_PLIST="
  <key>SUFeedURL</key><string>${SPARKLE_FEED_URL}</string>
  <key>SUPublicEDKey</key><string>${SPARKLE_PUBLIC_ED_KEY}</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUAllowsAutomaticUpdates</key><false/>
  <key>SURequireSignedFeed</key><true/>
  <key>SUVerifyUpdateBeforeExtraction</key><true/>
  <key>SUShowReleaseNotes</key><true/>"
fi

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
  <key>CFBundleVersion</key><string>${BUILD_VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
${SPARKLE_PLIST}
</dict>
</plist>
PLIST

SIGN_IDENTITY="${CLAUDE_DASH_CODE_SIGN_IDENTITY:--}"
SIGN_ARGS=(--force --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  SIGN_ARGS+=(--timestamp=none)
else
  # A Developer ID build needs hardened runtime and a trusted timestamp.
  SIGN_ARGS+=(--options runtime --timestamp)
fi

sign() {
  /usr/bin/codesign "${SIGN_ARGS[@]}" "$@"
}

echo "==> Signing Sparkle helpers and app (${SIGN_IDENTITY})"
# Sparkle's XPC services and updater need inner-to-outer signing. Do not use
# --deep for signing: the Downloader has its own entitlement metadata that must
# survive re-signing (Sparkle's documented manual-distribution sequence).
SPARKLE_IN_APP="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$SPARKLE_IN_APP/XPCServices/Installer.xpc"
/usr/bin/codesign "${SIGN_ARGS[@]}" --preserve-metadata=entitlements \
  "$SPARKLE_IN_APP/XPCServices/Downloader.xpc"
sign "$SPARKLE_IN_APP/Autoupdate"
sign "$SPARKLE_IN_APP/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign "$APP"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"

if [[ "$SPARKLE_ENABLED" == "1" ]]; then
  echo "==> Done: $APP (v${VERSION}, build ${BUILD_VERSION}, signed Sparkle updates enabled)"
else
  echo "==> Done: $APP (v${VERSION}, build ${BUILD_VERSION}, manual GitHub-release update fallback)"
fi
