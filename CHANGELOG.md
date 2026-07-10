# Changelog

## 1.6.0 — 2026-07-10

- Remember multiple local Codex identities so Personal and Team usage remain
  visible together, with the active account first and per-account notes.
- Correct Codex freshness by comparing embedded `token_count` timestamps across
  active and archived tasks, and label every value explicitly as used or left.
- Replace the blanket “session key expired” state with confirmed sign-in,
  Keychain, access, rate-limit, network, service, and response-change errors;
  retain the last-good usage snapshot and provide retry/status recovery.
- Add independent 90%–160% text zoom for Quick Glance and Board, including
  Command/Option plus and minus shortcuts and adaptive window sizing.
- Add signed Sparkle updates with background discovery and in-app installation,
  backed by isolated RC/production feeds, verified archives/appcasts, and a
  fail-closed GitHub release workflow. Apple Developer Program membership is
  not required; the first unnotarized install retains the documented Gatekeeper
  tradeoff.

