#!/usr/bin/env bash
set -euo pipefail

# Claude Dash installer — builds from source into /Applications.
# Usage:
#   git clone https://github.com/brianyoungilcho/claude-dash.git && cd claude-dash && ./install.sh
# Re-run after `git pull` to upgrade (restarts the app on the new build).

if ! xcode-select -p >/dev/null 2>&1; then
  echo "Xcode Command Line Tools are required (provides the Swift compiler)."
  echo "Install them with:  xcode-select --install"
  echo "…then re-run ./install.sh"
  exit 1
fi

ROOT="$(cd "$(dirname "$0")" && pwd)"
"$ROOT/build.sh"

# Restart if an older instance is running, so the new build actually takes over.
pkill -f "Claude Dash.app/Contents/MacOS/ClaudeDash" 2>/dev/null && sleep 1 || true
open "/Applications/Claude Dash.app"
echo
echo "Claude Dash is running — look for the gauge icon in your menu bar."
echo "Right-click it → Add Account… to connect your first Claude account."
echo "(It registers itself to start at login automatically.)"
