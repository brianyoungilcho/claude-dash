# Claude Dash

![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-blue)
![License](https://img.shields.io/badge/license-MIT-green)
![Release](https://img.shields.io/github/v/release/brianyoungilcho/claude-dash)

One menu-bar app for juggling multiple Claude accounts: every account's usage
at a glance, one click to open claude.ai in the right browser profile.

![Dashboard](docs/panel-dark.png)

- **Menu-bar gauges** — a mini usage bar per account, always visible
  (or tightest-account-only / icon-only, your pick).
- **Floating dashboard** — every account with its **5-hour session** bar
  (+ reset countdown), **weekly** limit, **per-model weekly caps** (e.g.
  Fable), and **extra-usage credits** when enabled — each with its own reset
  time. **Open** launches claude.ai in that account's browser profile.
- **Burn-rate warning** — "at this pace, caps 12:09 PM" when your current
  session pace would hit the limit before the reset.
- **In-app sign-in** — adding an account opens a claude.ai login window and
  captures the session key automatically; no DevTools digging. (Manual
  cookie-paste still works.)
- **Same email, multiple workspaces?** Fine — usage is tracked per
  *organization*; pick the org when adding the account.
- **Notifications** — configurable threshold alert, plus a "session reset —
  good to go" ping for capped accounts.
- Keys live in the **macOS Keychain**, never on disk. Works with **Chrome,
  Brave, Edge, or Chromium** profiles. Global hotkey **⌃⌥⌘D**. Universal
  binary (Apple Silicon + Intel).

## Install

Requires macOS 13+ and the Xcode Command Line Tools
(`xcode-select --install` — one-time, no full Xcode needed).

```bash
git clone https://github.com/brianyoungilcho/claude-dash.git && cd claude-dash && ./install.sh
```

Or via Homebrew (`--no-quarantine` because the app isn't notarized):

```bash
brew install --cask --no-quarantine brianyoungilcho/tap/claude-dash
```

That's it: builds a universal binary into `/Applications/Claude Dash.app`,
launches it, and registers it to start at login (once — disable it in
System Settings or Preferences and your choice sticks). Local builds have no
Gatekeeper friction. Upgrade with `git pull && ./install.sh`.

> **Prebuilt zip from [Releases](https://github.com/brianyoungilcho/claude-dash/releases)
> instead?** The app is ad-hoc signed, not notarized, so "right-click → Open"
> does NOT work on current macOS. Instead: unzip, **drag `Claude Dash.app`
> into `/Applications`** (required — running from Downloads breaks
> start-at-login via App Translocation), then clear quarantine:
> `xattr -dr com.apple.quarantine "/Applications/Claude Dash.app"` and open it.

## Add an account

![Add account](docs/add-account.png)

1. Menu-bar gauge icon → right-click → **Add Account…** (or the dashboard's
   "Add account…" button).
2. Click **Sign in…** and log into the Claude account — the session key is
   captured automatically and validated. (Manual fallback: copy the
   `sessionKey` cookie from DevTools in that browser profile.)
3. Pick the **organization** (chat orgs listed first; API-console orgs are
   labeled and can't serve usage) and the **browser profile** it should open
   with. Usage is verified live before saving, so a wrong pick fails loudly
   here, not silently later.

Session keys rotate periodically. When one dies, the row turns red — **⋯ →
Edit… → Sign in…** gets a fresh one in seconds.

## Preferences

Gear icon in the dashboard (or right-click → Preferences…): refresh interval,
account sort order (added / most headroom / most used), menu-bar display mode,
used-vs-remaining labels, notification threshold + reset alerts,
launch-at-login, hotkey.

Power-user overrides via `defaults` (browser selection):

```bash
defaults write com.claudedash.app browserAppName "Brave Browser"
defaults write com.claudedash.app browserSupportSubpath "BraveSoftware/Brave-Browser"
```

## How it works

Usage comes from claude.ai's internal
`GET /api/organizations/{orgUuid}/usage` — the same endpoint the claude.ai
usage page reads — authenticated by the session-key cookie. It returns
percentages, not token counts. The parser prefers the modern `limits[]` array
(session / weekly_all / per-model weekly_scoped) with legacy-field fallback,
so new model caps appear automatically.

**Disclaimer:** unofficial, community-built, not affiliated with Anthropic.
The endpoint is internal and can change without notice — if every account
errors at once, check for a newer release. Session keys grant full account
access: they're stored only in your local Keychain and sent only to claude.ai.
Use at your own risk.

More: [FAQ](FAQ.md) · [Uninstall](#uninstall) · [Development](#development)

## Uninstall

```bash
osascript -e 'quit app "Claude Dash"'
rm -rf "/Applications/Claude Dash.app"
defaults delete com.claudedash.app
security delete-generic-password -s com.claudedash.sessionkey || true  # repeat until "not found"
```

Then remove the stale "Claude Dash" entry under **System Settings → General →
Login Items**, if one remains.

## Development

| Path | Contents |
|------|----------|
| `Sources/Core.swift` | Models, Keychain (via `security` CLI), browser/profile discovery, `UsageAPI` |
| `Sources/AppModel.swift` | Observable state, polling, pace projection, notifications |
| `Sources/Views.swift` | SwiftUI: dashboard, metric rows, add/edit sheets, preferences |
| `Sources/Prefs.swift` | Typed UserDefaults settings |
| `Sources/WebSignIn.swift` | In-app claude.ai login window (isolated cookie store) |
| `Sources/main.swift` | App bootstrap, floating panel, menu bar, hotkey, update check |
| `build.sh` | Universal (arm64+x86_64) build + bundle + ad-hoc sign |
| `Tests/main.swift` | Headless tests (CI-safe; live-endpoint check runs locally) |
| `Preview/main.swift` | Renders the views to PNG for design review |

```bash
mkdir -p .build

# run tests
swiftc -swift-version 5 -o .build/tests Tests/main.swift Sources/Core.swift && ./.build/tests

# render the views to PNGs (Preview has its own main.swift, so exclude Sources/main.swift)
swiftc -swift-version 5 -o .build/preview Preview/main.swift \
  Sources/Core.swift Sources/AppModel.swift Sources/Views.swift \
  Sources/Prefs.swift Sources/WebSignIn.swift \
  -framework AppKit -framework SwiftUI -framework WebKit -framework UserNotifications
OUT=/tmp ./.build/preview
```

CI builds both architectures and runs the test suite on every push; tagging
`v*` builds and publishes a release zip automatically.

**Roadmap / non-goals:** configurable hotkey is planned.
Out of scope by design: local JSONL cost analytics (use
[ccusage](https://github.com/ryoppippi/ccusage)), multi-provider quota
tracking, Claude Code credential rotation.

MIT licensed.
