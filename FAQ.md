# FAQ

**The app is running but there's no icon in the menu bar.**
Three usual causes: (1) On a notched Mac running macOS 26, an older build's
icon could get parked in the hidden area left of the notch and never drawn —
**update to v1.5.3 or later**, which places it in a visible slot on first
launch. If an icon is still hidden, ⌘-drag it to the right of the notch.
(There is no per-app "menu bar" permission toggle in macOS 26; don't go looking
for one.) (2) A crowded menu bar (especially on notched MacBooks) silently hides
items that don't fit — quit something or ⌘-drag icons to make room. (3) In
Preferences, "Menu bar shows: All accounts" grows with each account; switch to
"Tightest account only" or "Icon only" if you track many.

**macOS says the app is damaged / can't be opened (downloaded zip).**
The prebuilt zip is ad-hoc signed, not notarized, and "right-click → Open" no
longer bypasses Gatekeeper on modern macOS. Move the app to `/Applications`
first, then run:
`xattr -dr com.apple.quarantine "/Applications/Claude Dash.app"`.
Building from source (`./install.sh`) avoids this entirely.

**Why does an account keep saying "session key expired"?**
Session keys rotate. The fastest fix is the row's **⋯ → Edit… → Sign in…**
button, which captures a fresh key automatically. If you copy cookies manually,
reload claude.ai first and confirm you're logged in — a logged-out tab shows a
stale cookie.

**The Sign in… window rejects my Google login.**
Some identity providers refuse embedded web views. Fall back to the manual
path: in the browser profile that's logged in, open claude.ai → DevTools (⌥⌘I)
→ Application → Cookies → `https://claude.ai` → copy the `sessionKey` value and
paste it.

**Where are my session keys stored?**
In your macOS login Keychain (service `com.claudedash.sessionkey`), written via
Apple's `security` tool so the ad-hoc-signed app never triggers keychain
password prompts. Trade-off: like Claude Code's own credentials, the items are
readable by CLI tools running as your user. Keys never touch disk in cleartext
and are only ever sent to claude.ai.

**Which browsers work?**
Chromium-family browsers with profiles: Chrome, Brave, Edge, Chromium
(auto-detected in that order). Override:
```
defaults write com.claudedash.app browserAppName "Brave Browser"
defaults write com.claudedash.app browserSupportSubpath "BraveSoftware/Brave-Browser"
```
Safari, Firefox, and Arc don't expose Chromium-style profile switching.

**Can I move the icon in the menu bar?**
macOS owns menu-bar ordering — ⌘-drag the icon wherever you like.

**The ⌃⌥⌘D hotkey conflicts with another app.**
Turn it off in Preferences. (Configurable combos are on the roadmap.)

**Numbers look different from claude.ai's usage page.**
Both read the same source; the dashboard polls on an interval (default 1 min),
so brief divergence right after heavy usage is expected. Hit refresh to sync.

**How do I finish editing a note?**
Click anywhere outside it, press Esc, or press ⌘⏎ (or the Done button). Notes
save automatically either way — there's no separate save step.

**Removing an account asks for confirmation now.**
Yes — because it also deletes that account's stored session key and any note
you wrote for it, and that can't be undone.

**Where are my notes stored? Do they sync?**
`~/Library/Application Support/Claude Dash/notes.json` — plain JSON on this
Mac only. No cloud, no sync, nothing sent anywhere. Back the file up (or sync
it yourself) if the notes matter.

**Can I track Personal and TEAM Codex accounts at the same time?**
Yes. Claude Dash keeps a separate local card, note, nickname, and last-known
usage snapshot for every Codex account it safely observes. After switching the
Codex login, it puts the current account first as a pending card; start a
**new Codex task** and send one prompt to capture it. Codex's historical
rollout files do not identify the account that wrote them, so Dash refuses to
guess from an old task and risk showing TEAM usage as Personal (or vice versa).
The other cards stay visible with their own “as of…” timestamp. The `…` menu
can rename a card or forget its local cache and note; neither action changes
anything in Codex. Codex writes `used_percent`; Dash labels each saved value
explicitly as **used** or **left** based on your display setting. A snapshot
older than an hour or past its reset warns that a new Codex prompt is needed,
instead of claiming the cached number is live.

**Does Codex tracking store or send my OpenAI credentials?**
No. It reads local rollout rate-limit snapshots plus non-secret display claims
from the active `~/.codex/auth.json` JWT. OAuth/access/refresh tokens and the
raw account id are never logged or persisted. The local Claude Dash cache uses
only a hash-derived account key and has owner-only file permissions.

**What do the Claude Code hooks actually do?**
Optional (Preferences → Install). They add two entries to
`~/.claude/settings.json` (a backup is written first) that append one JSON
line per event to a local file, so the board can show "waiting for your
input." Sessions appear on the card of the account whose organization the
CLI is logged into (falling back to a separate section only when no account
matches). They run locally, add ~no overhead, and Remove in Settings puts
everything back. Your existing hooks are preserved — entries are merged, not
overwritten.

**Why don't the conversations under an account update instantly?**
They refresh every ~5 minutes (piggybacked on usage polls) to keep requests
polite; the refresh button forces an immediate update.

**Why is the conversations list empty (or missing chats I'd expect)?**
It shows web chats from the last 48 hours only — older items are hidden as
noise. Claude Code / API usage burns quota without creating web
conversations, so a busy account can legitimately show none.

**Is this an official Anthropic app?**
No — unofficial, community-built. It reads the same internal endpoint the
claude.ai usage page uses, which can change without notice. If every account
errors at once, check for a newer release.
