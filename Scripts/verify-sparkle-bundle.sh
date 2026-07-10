#!/usr/bin/env bash
set -euo pipefail

# Verify the invariants that are easy to lose in a non-Xcode build: the
# framework must be embedded, the executable must locate it through @rpath,
# both architecture slices must remain, and nested code signatures must be
# intact. Set CLAUDE_DASH_REQUIRE_SPARKLE=1 for a release that must have a
# configured signed feed.
APP="${1:-/Applications/Claude Dash.app}"
BIN="$APP/Contents/MacOS/ClaudeDash"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
PLIST="$APP/Contents/Info.plist"

[[ -x "$BIN" ]] || { echo "Missing app executable: $BIN" >&2; exit 1; }
[[ -x "$FRAMEWORK/Sparkle" ]] || { echo "Missing embedded Sparkle.framework" >&2; exit 1; }

arches="$(/usr/bin/lipo -archs "$BIN")"
[[ " $arches " == *" arm64 "* && " $arches " == *" x86_64 "* ]] || {
  echo "Claude Dash is not universal: $arches" >&2; exit 1
}

/usr/bin/otool -L "$BIN" | /usr/bin/grep -Fq '@rpath/Sparkle.framework/Versions/B/Sparkle' || {
  echo "Claude Dash does not link Sparkle through the embedded @rpath" >&2; exit 1
}

/usr/bin/codesign --verify --deep --strict --verbose=2 "$FRAMEWORK"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"

public_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PLIST" 2>/dev/null || true)"
feed_url="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$PLIST" 2>/dev/null || true)"
if [[ -z "$public_key" && -z "$feed_url" ]]; then
  if [[ "${CLAUDE_DASH_REQUIRE_SPARKLE:-0}" == "1" ]]; then
    echo "Release requires Sparkle, but this bundle is deliberately in fallback mode" >&2
    exit 1
  fi
  echo "==> Bundle is valid; updater remains in manual GitHub-release fallback mode"
  exit 0
fi

[[ "$public_key" =~ ^[A-Za-z0-9+/]{43}=$ ]] || {
  echo "SUPublicEDKey is missing or malformed" >&2; exit 1
}
[[ "$feed_url" == https://* ]] || {
  echo "SUFeedURL must be an HTTPS URL" >&2; exit 1
}
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SURequireSignedFeed' "$PLIST")" == "true" ]] || {
  echo "Sparkle release must require a signed appcast" >&2; exit 1
}

echo "==> Bundle is valid with signed Sparkle updates enabled"
