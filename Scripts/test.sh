#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/.build"

swiftc -swift-version 5 -o "$ROOT/.build/tests" \
  "$ROOT/Tests/main.swift" "$ROOT/Sources/Core.swift" "$ROOT/Sources/Prefs.swift" "$ROOT/Sources/Notes.swift" \
  "$ROOT/Sources/ClaudeCode.swift" "$ROOT/Sources/Codex.swift" "$ROOT/Sources/Updater.swift" \
  -framework AppKit
"$ROOT/.build/tests"
