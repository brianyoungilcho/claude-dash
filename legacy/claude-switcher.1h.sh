#!/usr/bin/env bash
# <xbar.title>Claude Account Switcher</xbar.title>
# <xbar.version>v1.0</xbar.version>
# <xbar.author>you</xbar.author>
# <xbar.desc>One-click: open claude.ai in the right Chrome profile. Auto-discovers your Chrome profiles.</xbar.desc>
# <xbar.dependencies>macOS, Google Chrome, SwiftBar</xbar.dependencies>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
#
# HOW IT WORKS
#   Reads Chrome's "Local State" file to list every Chrome profile (name + signed-in
#   email), then shows a menu bar dropdown. Clicking a profile opens a new claude.ai
#   chat in that Chrome profile. Each profile also has a submenu with its Usage page
#   and chat history. No credentials are read or stored -- only profile names.
#
# SETUP
#   1. Install SwiftBar:  brew install --cask swiftbar
#   2. Drop this file into your SwiftBar plugin folder
#   3. chmod +x claude-switcher.1h.sh
#   (The ".1h" in the filename = SwiftBar rescans your profiles hourly.)
#
# CUSTOMIZE below: menu bar title, plan tags, hidden profiles, or a different
# Chromium browser (Brave/Edge/Canary).

# ----------------------------- configuration --------------------------------

MENUBAR_TITLE="Claude"          # e.g. "Cl", an emoji, or "Claude | sfimage=person.2.circle"

CHROME_APP="Google Chrome"      # Brave: "Brave Browser"   Edge: "Microsoft Edge"
CHROME_SUPPORT="${CLAUDE_SWITCHER_CHROME_SUPPORT:-$HOME/Library/Application Support/Google/Chrome}"
                                # Brave: .../BraveSoftware/Brave-Browser   Edge: .../Microsoft Edge

NEW_CHAT_URL="https://claude.ai/new"
USAGE_URL="https://claude.ai/settings/usage"
RECENTS_URL="https://claude.ai/recents"

# Optional: append a plan tag next to a profile, keyed by its Chrome profile
# directory (shown in each profile's submenu as "Profile dir: ...").
tag_for() {
  case "$1" in
    # "Default")   echo "Max 20x" ;;
    # "Profile 1") echo "Pro" ;;
    *) echo "" ;;
  esac
}

# Optional: hide Chrome profiles that have no Claude account.
hide_profile() {
  case "$1" in
    # "Profile 3") return 0 ;;
    *) return 1 ;;
  esac
}

# -------------------------- no edits needed below ---------------------------

LOCAL_STATE="$CHROME_SUPPORT/Local State"

clean() { printf '%s' "$1" | tr -d '"|' | tr -s ' ' ; }

emit_open() {  # $1 = profile dir, $2 = url  ->  prints SwiftBar action attributes
  printf 'bash="/usr/bin/open" param1="-na" param2="%s" param3="--args" param4="--profile-directory=%s" param5="%s" terminal=false' \
    "$CHROME_APP" "$1" "$2"
}

scan_profiles() {  # prints: dir <TAB> name <TAB> email, sorted by name
  [ -f "$LOCAL_STATE" ] || return 0
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$LOCAL_STATE" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    sys.exit(0)
cache = data.get("profile", {}).get("info_cache", {})
rows = []
for d, v in cache.items():
    if d in ("Guest Profile", "System Profile"):
        continue
    name = (v.get("name") or d).strip()
    email = (v.get("user_name") or "").strip()
    rows.append((name.lower(), d, name, email))
for _, d, name, email in sorted(rows):
    print(d + "\t" + name + "\t" + email)
PY
  else
    /usr/bin/osascript -l JavaScript -e '
ObjC.import("Foundation");
function run(argv) {
  var s = $.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null);
  if (!s || (s.isNil && s.isNil())) return "";
  var txt = ObjC.unwrap(s);
  var data; try { data = JSON.parse(txt); } catch (e) { return ""; }
  var cache = (data.profile && data.profile.info_cache) || {};
  var rows = [];
  for (var d in cache) {
    if (d === "Guest Profile" || d === "System Profile") continue;
    var v = cache[d] || {};
    rows.push([String(v.name || d).toLowerCase(), d, String(v.name || d), String(v.user_name || "")]);
  }
  rows.sort(function (a, b) { return a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0; });
  var out = [];
  for (var i = 0; i < rows.length; i++) out.push(rows[i][1] + "\t" + rows[i][2] + "\t" + rows[i][3]);
  return out.join("\n");
}' "$LOCAL_STATE" 2>/dev/null
  fi
}

PROFILES="$(scan_profiles)"

echo "$MENUBAR_TITLE"
echo "---"

if [ -z "$PROFILES" ]; then
  echo "No Chrome profiles found | color=red"
  echo "Looked in: $LOCAL_STATE | size=11"
  echo "Edit CHROME_APP / CHROME_SUPPORT at the top of this plugin | size=11"
else
  printf '%s\n' "$PROFILES" | while IFS=$'\t' read -r dir name email; do
    [ -n "$dir" ] || continue
    hide_profile "$dir" && continue
    name="$(clean "$name")"
    email="$(clean "$email")"
    tag="$(tag_for "$dir")"
    label="$name"
    [ -n "$tag" ] && label="$name · $tag"
    echo "$label | $(emit_open "$dir" "$NEW_CHAT_URL")"
    [ -n "$email" ] && echo "-- $email | size=11"
    echo "-- Usage page | $(emit_open "$dir" "$USAGE_URL")"
    echo "-- All chats | $(emit_open "$dir" "$RECENTS_URL")"
    echo "-- Profile dir: $dir | size=11"
  done
fi

echo "---"
echo "Rescan profiles | refresh=true"
echo "Reveal plugin in Finder | bash=\"/usr/bin/open\" param1=\"-R\" param2=\"$0\" terminal=false"
