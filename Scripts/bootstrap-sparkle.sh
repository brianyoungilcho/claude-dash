#!/usr/bin/env bash
set -euo pipefail

# Download Sparkle's pre-built universal distribution only when it is absent.
# Building Sparkle from source is intentionally avoided: the project documents
# that source-built framework copies can lose required signing metadata.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="2.9.4"
SHA256="ce89daf967db1e1893ed3ebd67575ed82d3902563e3191ca92aaec9164fbdef9"
URL="https://github.com/sparkle-project/Sparkle/releases/download/${VERSION}/Sparkle-${VERSION}.tar.xz"
DEST="$ROOT/Vendor/Sparkle"

valid_distribution() {
  local dir="$1"
  local framework="$dir/Sparkle.framework"
  local info="$framework/Versions/B/Resources/Info.plist"
  [[ -x "$framework/Sparkle" ]] || return 1
  [[ -x "$dir/bin/generate_appcast" ]] || return 1
  [[ -x "$dir/bin/sign_update" ]] || return 1
  [[ -f "$info" ]] || return 1

  local found_version arches
  found_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info" 2>/dev/null || true)"
  [[ "$found_version" == "$VERSION" ]] || return 1
  arches="$(/usr/bin/lipo -archs "$framework/Sparkle" 2>/dev/null || true)"
  [[ " $arches " == *" arm64 "* && " $arches " == *" x86_64 "* ]]
}

if valid_distribution "$DEST"; then
  echo "==> Sparkle ${VERSION} is ready"
  exit 0
fi

mkdir -p "$ROOT/Vendor"
tmp="$(mktemp -d "$ROOT/Vendor/.sparkle.XXXXXX")"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

archive="$tmp/Sparkle-${VERSION}.tar.xz"
echo "==> Downloading Sparkle ${VERSION}"
curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --retry-delay 1 \
  --output "$archive" "$URL"

actual_sha="$(/usr/bin/shasum -a 256 "$archive" | /usr/bin/awk '{print $1}')"
if [[ "$actual_sha" != "$SHA256" ]]; then
  echo "Sparkle checksum mismatch: expected ${SHA256}, got ${actual_sha}" >&2
  exit 1
fi

mkdir "$tmp/extracted" "$tmp/payload"
tar -xJf "$archive" -C "$tmp/extracted"
ditto "$tmp/extracted/Sparkle.framework" "$tmp/payload/Sparkle.framework"
ditto "$tmp/extracted/bin" "$tmp/payload/bin"
cp "$tmp/extracted/LICENSE" "$tmp/payload/LICENSE"

if ! valid_distribution "$tmp/payload"; then
  echo "Sparkle ${VERSION} did not contain the expected universal framework and tools" >&2
  exit 1
fi

# A valid old copy is never removed. An incomplete/corrupt generated copy may
# be replaced only after the new payload has passed all checks above.
if [[ -e "$DEST" ]]; then
  rm -rf "$DEST"
fi
mv "$tmp/payload" "$DEST"
echo "==> Installed verified Sparkle ${VERSION} at $DEST"
