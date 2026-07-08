# AGENTS.md — Claude Dash

Guide for AI agents helping a user install, use, or develop Claude Dash — a
native macOS menu-bar app (Swift/SwiftUI, plain `swiftc`, no Xcode project)
that shows claude.ai usage limits across multiple accounts and opens claude.ai
in the right browser profile.

## Installing for a user (the most common task)

1. **Requirements**: macOS 13+, Xcode Command Line Tools.
   Check with `xcode-select -p`. If missing, run `xcode-select --install` —
   this pops a **macOS GUI dialog the user must click through** (it renders in
   their OS language). Warn them it's coming, then WAIT until they confirm the
   install finished before continuing. It can take several minutes.
2. **Install**:
   ```bash
   git clone https://github.com/brianyoungilcho/claude-dash.git
   cd claude-dash && ./install.sh
   ```
   This compiles a universal binary into `/Applications/Claude Dash.app`,
   ad-hoc signs it, launches it, and registers it to start at login. No
   Homebrew or other dependencies are needed. Never pipe curl to bash.
3. **Verify**: `pgrep -f "Claude Dash.app/Contents/MacOS/ClaudeDash"` returns a
   PID, and a small **gauge icon appears in the menu bar** at the top-right of
   the screen (describe it visually — menu-bar strings vary by OS language).
   If the process runs but no icon shows on a notched macOS 26 Mac, the
   status item was parked in the left-of-notch overflow region (where macOS
   never draws status items) because it had no persisted position — fixed in
   v1.5.3, which sets `autosaveName`/preferred-position in `setupStatusItem`
   (there is **no** per-app menu-bar allow-list in macOS 26; don't look for one).
   Diagnose with `screencapture` of the menu bar plus `osascript` reading the
   position of `menu bar item 1 of menu bar 2` of the ClaudeDash process — an
   item x < ~826 on a 1512-pt display is parked left of the notch and hidden.
   Exceptions log to `/tmp/claudedash-debug.log`.
4. **First account**: right-click the gauge icon → **Add Account…** → prefer
   the **Sign in…** button (opens a claude.ai login window and captures the
   session key automatically). If the login provider refuses the embedded
   window, fall back to the manual cookie path described in the README.
   Same email with multiple workspaces is fine — usage is per organization,
   picked during add.

## Rules

- Session keys are credentials. The app stores them in the macOS Keychain —
  never write them to files, echo them, or paste them into chat.
- The usage endpoint is unofficial claude.ai API — don't poll it outside the
  app (the app's default 60s interval is the intended rate).
- Don't disable Gatekeeper globally or modify security settings; the
  source-build path needs no Gatekeeper workarounds at all.

## Developing

- **Build + install**: `./build.sh` (universal arm64+x86_64 →
  `/Applications/Claude Dash.app`; version via `CLAUDE_DASH_VERSION` env —
  CI derives it from the git tag).
- **Tests**:
  ```bash
  mkdir -p .build
  swiftc -swift-version 5 -o .build/tests Tests/main.swift Sources/Core.swift Sources/Notes.swift Sources/ClaudeCode.swift Sources/Codex.swift && ./.build/tests
  ```
  The live-endpoint and browser-profile checks self-skip when `$CI` is set.
- **View renders** (design review without launching the app):
  ```bash
  swiftc -swift-version 5 -o .build/preview Preview/main.swift \
    Sources/Core.swift Sources/AppModel.swift Sources/Views.swift \
    Sources/Prefs.swift Sources/WebSignIn.swift Sources/Notes.swift Sources/ClaudeCode.swift Sources/Codex.swift Sources/Board.swift \
    -framework AppKit -framework SwiftUI -framework WebKit -framework UserNotifications
  OUT=/tmp ./.build/preview
  ```
- **Layout**: `Sources/Core.swift` (models, Keychain via `security` CLI,
  `UsageAPI`), `AppModel.swift` (state/polling), `Views.swift` (SwiftUI),
  `Prefs.swift` (settings), `WebSignIn.swift` (login window), `Board.swift`
  (standalone board window), `Codex.swift` (local `~/.codex` usage read),
  `main.swift`
  (panel, menu bar, hotkey). Tests and Preview each have their own
  `main.swift` — never compile them together with `Sources/main.swift`.

### Gotchas that have already bitten

- Ad-hoc signing changes identity every rebuild → SecItem keychain reads
  prompt for passwords. That's why all keychain access shells out to
  `/usr/bin/security` (stable Apple-signed accessor). Don't "simplify" it
  back to the SecItem API.
- `.canJoinAllSpaces` + `.moveToActiveSpace` are mutually exclusive window
  behaviors — setting both throws inside `applicationDidFinishLaunching` and
  AppKit swallows it, leaving the app alive with no menu-bar icon.
- SwiftUI `ImageRenderer` renders light-mode by default; the menu-bar image
  must match the bar's `effectiveAppearance` or dark-bar text goes invisible.
- claude.ai's WAF rejects non-browser TLS fingerprints (Python urllib gets
  403 with the right headers); use URLSession for any endpoint probing.
- Block-based NotificationCenter observers must be removed via their token —
  `removeObserver(self, …)` silently does nothing for them.

## Uninstalling for a user

```bash
osascript -e 'quit app "Claude Dash"'
rm -rf "/Applications/Claude Dash.app"
defaults delete com.claudedash.app
security delete-generic-password -s com.claudedash.sessionkey   # repeat until "not found"
```
Then remove the stale Login Items entry in System Settings if one remains.
