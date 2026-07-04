#!/usr/bin/env bash
set -euo pipefail

# Claude Dash installer — builds from source into /Applications.
# Usage:
#   git clone <repo-url> && cd claude-dash && ./install.sh

if ! xcode-select -p >/dev/null 2>&1; then
  echo "Xcode Command Line Tools are required (provides the Swift compiler)."
  echo "Install them with:  xcode-select --install"
  echo "…then re-run ./install.sh"
  exit 1
fi

ROOT="$(cd "$(dirname "$0")" && pwd)"
"$ROOT/build.sh"

open "/Applications/Claude Dash.app"
echo
echo "Claude Dash is running — look for the gauge icon in your menu bar."
echo "Right-click it → Add Account… to connect your first Claude account."
echo "(It registers itself to start at login automatically.)"
