# Claude Dash

One menu-bar app for juggling multiple Claude accounts: every account's usage
at a glance, and one click to open claude.ai in the right browser profile.

![Dashboard](docs/panel-dark.png)

- **Menu-bar gauges** — a mini usage bar per account, always visible.
- **Floating dashboard** — click the menu-bar icon: every account with its
  **5-hour session** bar (+ reset countdown), **weekly** limit, and any
  **per-model weekly caps** (e.g. Fable) — each with its own reset time.
  The **Open** button launches claude.ai in that account's browser profile.
- **Same email, multiple workspaces?** Fine — usage is tracked per
  *organization*; pick the org when adding the account.
- Keys are stored in the **macOS Keychain**, never on disk. Threshold
  notification when an account crosses 90% of its session limit.
- Works with **Chrome, Brave, Edge, or Chromium** profiles (auto-detected).

## Install

Requires macOS 13+ and the Xcode Command Line Tools
(`xcode-select --install` — one-time, no full Xcode needed).

```bash
git clone <REPO_URL> && cd claude-dash && ./install.sh
```

That's it: builds a universal binary into `/Applications/Claude Dash.app`,
launches it, and it registers itself to start at login. Local builds have no
Gatekeeper friction.

> **Prebuilt zip from Releases instead?** After unzipping, right-click →
> Open the app the first time (it's ad-hoc signed, not notarized), or run
> `xattr -dr com.apple.quarantine "/Applications/Claude Dash.app"`.

## Add an account

![Add account](docs/add-account.png)

1. Menu-bar gauge icon → right-click → **Add Account…**
2. In the browser profile that's logged into that Claude account: open
   `claude.ai` → DevTools (⌥⌘I) → **Application → Cookies →
   https://claude.ai** → copy the `sessionKey` value (starts with `sk-ant-`).
3. Paste → **Validate key** → pick the **organization** (chat orgs are listed
   first; API-console orgs are labeled and won't work for usage) → pick the
   **browser profile** → **Add account**. Usage is verified live before the
   account is saved, so a wrong org fails loudly at this step, not silently
   later.

Session keys expire periodically. When one does, the row turns red with a
**Replace session key** button — repeat step 2 for that account (~1 minute).

## Configuration

Everything has sensible defaults; overrides via `defaults`:

```bash
# Use a specific Chromium-family browser instead of the auto-detected one:
defaults write com.claudedash.app browserAppName "Brave Browser"
defaults write com.claudedash.app browserSupportSubpath "BraveSoftware/Brave-Browser"
```

Polling is every 60s. Notification threshold is 90% of the session limit.

## How it works / troubleshooting

Usage comes from claude.ai's internal
`GET /api/organizations/{orgUuid}/usage`, authenticated by the session-key
cookie (the same endpoint the claude.ai usage page uses). It returns
percentages, not token counts. Being an internal endpoint, it can change
without notice — if all accounts suddenly error, check for a newer Claude
Dash; the whole network layer is one function (`UsageAPI` in
`Sources/Core.swift`).

- **"Session key expired" right after adding** — the claude.ai tab you copied
  the cookie from was probably logged out; reload it, confirm you're logged
  in, copy the fresh `sessionKey`.
- **Keychain**: keys are stored via `/usr/bin/security` so the ad-hoc-signed
  app never triggers keychain password prompts across rebuilds. Consequence:
  the items are readable by CLI tools running as your user — the same model
  Claude Code uses for its own credentials.
- **No accounts in the org picker** — that login has no organizations
  (unusual); log into claude.ai in the browser first.
- Debug log (exceptions only): `/tmp/claudedash-debug.log`.

## Uninstall

```bash
osascript -e 'quit app "Claude Dash"'
rm -rf "/Applications/Claude Dash.app"
defaults delete com.claudedash.app
security delete-generic-password -s com.claudedash.sessionkey || true  # repeat until "not found"
```

## Development

| Path | Contents |
|------|----------|
| `Sources/Core.swift` | Models, Keychain (via `security` CLI), browser/profile discovery, `UsageAPI` |
| `Sources/AppModel.swift` | Observable state, polling, add/remove/open actions |
| `Sources/Views.swift` | SwiftUI: dashboard, metric rows, gauges, add-account sheet |
| `Sources/main.swift` | App bootstrap, floating panel, menu-bar controller, login item |
| `build.sh` | Universal (arm64+x86_64) build + bundle + ad-hoc sign |
| `Tests/main.swift` | Headless tests: parsing (real captured fixtures), Keychain, live endpoint |
| `Preview/main.swift` | Renders the views to PNG (`OUT=dir ./.build/preview`) for design review |
| `Assets/gen-icon.swift` | Regenerates the app icon |

```bash
# run tests
swiftc -swift-version 5 -o .build/tests Tests/main.swift Sources/Core.swift && ./.build/tests
```

MIT licensed.
