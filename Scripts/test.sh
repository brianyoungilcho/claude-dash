#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/.build"

swiftc -swift-version 5 -o "$ROOT/.build/tests" \
  "$ROOT/Tests/main.swift" "$ROOT/Sources/Core.swift" "$ROOT/Sources/Prefs.swift" "$ROOT/Sources/Notes.swift" \
  "$ROOT/Sources/ClaudeCode.swift" "$ROOT/Sources/Codex.swift" "$ROOT/Sources/Updater.swift" \
  -framework AppKit
"$ROOT/.build/tests"

echo "== Release version metadata =="
production="$("$ROOT/Scripts/release-metadata.sh" v1.6.0)"
rc1="$("$ROOT/Scripts/release-metadata.sh" v1.6.0-rc.1)"
rc2="$("$ROOT/Scripts/release-metadata.sh" v1.6.0-rc.2)"
grep -Fqx 'version=1.6.0' <<< "$production"
grep -Fqx 'build_version=1060099' <<< "$production"
grep -Fqx 'prerelease=false' <<< "$production"
grep -Fqx 'feed_filename=appcast.xml' <<< "$production"
grep -Fqx 'build_version=1060001' <<< "$rc1"
grep -Fqx 'prerelease=true' <<< "$rc1"
grep -Fqx 'feed_filename=appcast-rc.xml' <<< "$rc1"
grep -Fqx 'build_version=1060002' <<< "$rc2"
if "$ROOT/Scripts/release-metadata.sh" v1.6.0-beta.1 >/dev/null 2>&1; then
  echo "Invalid release tag was accepted" >&2
  exit 1
fi
echo "  PASS  RC builds increase monotonically below production and invalid tags fail closed"
