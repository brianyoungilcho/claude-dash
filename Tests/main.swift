import Foundation

var failures = 0
func check(_ label: String, _ cond: Bool) {
    print(cond ? "  PASS  \(label)" : "  FAIL  \(label)")
    if !cond { failures += 1 }
}

print("== 1. Usage JSON decode — modern limits[] shape (captured live 2026-07-04) ==")
let fixture = """
{
  "five_hour":  { "utilization": 20, "resets_at": "2026-07-04T06:19:59.699944+00:00" },
  "seven_day":  { "utilization": 4, "resets_at": "2026-07-10T16:59:59.699968+00:00" },
  "seven_day_opus": null,
  "seven_day_sonnet": null,
  "limits": [
    { "group": "session", "is_active": true, "kind": "session", "percent": 20,
      "resets_at": "2026-07-04T06:19:59.699944+00:00", "scope": null, "severity": "normal" },
    { "group": "weekly", "is_active": false, "kind": "weekly_all", "percent": 4,
      "resets_at": "2026-07-10T16:59:59.699968+00:00", "scope": null, "severity": "normal" },
    { "group": "weekly", "is_active": false, "kind": "weekly_scoped", "percent": 5,
      "resets_at": "2026-07-10T16:59:59.700297+00:00",
      "scope": { "model": { "display_name": "Fable", "id": null }, "surface": null },
      "severity": "normal" }
  ]
}
""".data(using: .utf8)!
if let u = UsageAPI.decodeUsage(fixture) {
    check("session = 20 (from limits[])", u.session?.utilization == 20)
    check("session resets_at parsed", u.session?.resetsAt != nil)
    check("weekly = 4 (from weekly_all)", u.weekly?.utilization == 4)
    check("weekly resets_at parsed", u.weekly?.resetsAt != nil)
    check("one scoped metric found", u.scoped.count == 1)
    check("scoped metric is Fable at 5%", u.scoped.first?.name == "Fable" && u.scoped.first?.metric.utilization == 5)
    check("Fable resets_at parsed", u.scoped.first?.metric.resetsAt != nil)
} else {
    check("decode returned a value", false)
}

print("== 2. Legacy fallback (no limits[]; string utilization; missing seven_day) ==")
let fixture2 = #"{ "five_hour": { "utilization": "77", "resets_at": "2026-07-04T03:15:22+00:00" } }"#.data(using: .utf8)!
if let u = UsageAPI.decodeUsage(fixture2) {
    check("legacy five_hour fallback works, string coerced to 77", u.session?.utilization == 77)
    check("resets_at without fractional seconds still parses", u.session?.resetsAt != nil)
    check("missing seven_day = nil (no crash)", u.weekly == nil)
    check("no scoped metrics invented", u.scoped.isEmpty)
} else {
    check("decode2 returned a value", false)
}

let onCI = ProcessInfo.processInfo.environment["CI"] != nil

print("== 3. Chrome profile discovery (real Local State) ==")
if onCI {
    print("  SKIP  (CI runner has no browser profiles)")
} else {
    let profiles = ChromeProfiles.all()
    check("found at least one Chrome profile", profiles.count > 0)
    print("        discovered \(profiles.count) profiles:")
    for p in profiles { print("          [\(p.dir)] \(p.label)") }
}

print("== 4. Keychain round-trip ==")
let testAccount = "test-\(UUID().uuidString)"
let secret = "sk-ant-sid01-test-value-\(Int.random(in: 1000...9999))"
check("store succeeds", Keychain.set(secret, account: testAccount))
check("read matches", Keychain.get(account: testAccount) == secret)
Keychain.delete(account: testAccount)
check("delete removes it", Keychain.get(account: testAccount) == nil)

print("== 6. Notes: checkbox parser + toggle round-trip ==")
let note = "context line\n- [ ] ship board\n- [x] write tests\nplain end"
let lines = NoteParser.lines(note)
check("4 lines parsed", lines.count == 4)
check("line 1 = open checkbox", lines[1] == .checkbox(done: false, text: "ship board"))
check("line 2 = done checkbox", lines[2] == .checkbox(done: true, text: "write tests"))
let toggled = NoteParser.toggle(note, line: 1)
check("toggle marks done", NoteParser.lines(toggled)[1] == .checkbox(done: true, text: "ship board"))
check("double-toggle restores original", NoteParser.toggle(toggled, line: 1) == note)
check("toggling a plain line is a no-op", NoteParser.toggle(note, line: 0) == note)

print("== 7. Notes persistence round-trip (Codable) ==")
var nd = NotesData()
nd.global = "scratch ✍️"
nd.accounts["id1"] = AccountNote(text: "- [ ] renew key", flagged: true, updatedAt: Date())
if let enc = try? JSONEncoder().encode(nd), let dec = try? JSONDecoder().decode(NotesData.self, from: enc) {
    check("notes encode/decode round-trips", dec.global == nd.global
          && dec.accounts["id1"]?.flagged == true
          && dec.accounts["id1"]?.text == "- [ ] renew key")
} else { check("notes codable round-trip", false) }

print("== 8. Claude Code: sessions from hook events + hooks merge (temp fixture) ==")
let tmpEvents = FileManager.default.temporaryDirectory
    .appendingPathComponent("cdash-events-\(UUID().uuidString).jsonl")
let nowTs = Int(Date().timeIntervalSince1970)
let eventsFixture = """
{"event":"Stop","ts":\(nowTs - 7200),"payload":{"cwd":"/Users/alice/old_project"}}
{"event":"Notification","ts":\(nowTs - 300),"payload":{"cwd":"/Users/alice/my_project"}}
{"event":"Stop","ts":\(nowTs - 60),"payload":{"cwd":"/Users/alice/webapp"}}
not json garbage line
"""
try! eventsFixture.data(using: .utf8)!.write(to: tmpEvents)
let sessions = ClaudeCodeMonitor.sessionsFromEvents(eventsURL: tmpEvents)
check("two sessions within the window (old one excluded)", sessions.count == 2)
check("newest first", sessions.first?.projectDisplay == "webapp")
check("waiting = last event is Notification", sessions.last?.waiting == true && sessions.last?.projectDisplay == "my_project")
check("stopped session not waiting", sessions.first?.waiting == false)
check("display name = cwd last component (underscores intact)", sessions.last?.projectDisplay == "my_project")
try? FileManager.default.removeItem(at: tmpEvents)
check("no events file → no sessions", ClaudeCodeMonitor.sessionsFromEvents(eventsURL: tmpEvents).isEmpty)
let tmpSettings = FileManager.default.temporaryDirectory
    .appendingPathComponent("cdash-test-settings-\(UUID().uuidString).json")
let existing: [String: Any] = [
    "model": "opus",
    "hooks": ["Stop": [["hooks": [["type": "command", "command": "/usr/bin/true"]]]]],
]
try! JSONSerialization.data(withJSONObject: existing).write(to: tmpSettings)
_ = try? ClaudeCodeMonitor.installHooks(settingsURL: tmpSettings)
_ = try? ClaudeCodeMonitor.installHooks(settingsURL: tmpSettings)   // idempotency
if let data = try? Data(contentsOf: tmpSettings),
   let merged = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
   let hooks = merged["hooks"] as? [String: Any] {
    let stops = hooks["Stop"] as? [[String: Any]] ?? []
    let notifications = hooks["Notification"] as? [[String: Any]] ?? []
    check("pre-existing Stop hook preserved", stops.contains { e in
        ((e["hooks"] as? [[String: Any]]) ?? []).contains { ($0["command"] as? String) == "/usr/bin/true" } })
    check("our Stop hook appended exactly once (idempotent)", stops.count == 2)
    check("Notification hook added", notifications.count == 1)
    check("unrelated settings preserved", merged["model"] as? String == "opus")
    _ = try? ClaudeCodeMonitor.uninstallHooks(settingsURL: tmpSettings)
    if let d2 = try? Data(contentsOf: tmpSettings),
       let after = try? JSONSerialization.jsonObject(with: d2) as? [String: Any],
       let h2 = after["hooks"] as? [String: Any] {
        let stops2 = h2["Stop"] as? [[String: Any]] ?? []
        check("uninstall removes ours, keeps theirs", stops2.count == 1 && h2["Notification"] == nil)
    } else { check("uninstall readback", false) }
} else { check("hooks merge readback", false) }
try? FileManager.default.removeItem(at: tmpSettings)

print("== 8b. Footer staleness label ==")
let base = Date()
let fresh = updatedLabel(base.addingTimeInterval(-30), pollInterval: 60, now: base)
check("fresh is not stale", fresh?.stale == false)
let old = updatedLabel(base.addingTimeInterval(-300), pollInterval: 60, now: base)
check("5m old at 60s poll is stale", old?.stale == true)
check("stale shows relative minutes", old?.text == "Updated 5m ago")
check("nil date → no label", updatedLabel(nil, pollInterval: 60, now: base) == nil)
let hours = updatedLabel(base.addingTimeInterval(-7200), pollInterval: 60, now: base)
check("2h old shows hours", hours?.text == "Updated 2h ago")

print("== 9. Review-fix regressions ==")
// 9a. Toggle must only flip the LEADING marker, never one inside task text.
let tricky = "- [x] rename - [ ] placeholders in docs"
let untoggled = NoteParser.toggle(tricky, line: 0)
check("leading marker flipped, literal text preserved",
      untoggled == "- [ ] rename - [ ] placeholders in docs")
// 9b. Corrupt notes file → quarantined, not silently adopted-and-overwritten.
let tmpNotes = FileManager.default.temporaryDirectory
    .appendingPathComponent("cdash-notes-\(UUID().uuidString).json")
try! "{{{not json".data(using: .utf8)!.write(to: tmpNotes)
let loaded = NotesStore.load(from: tmpNotes)
let quarantined = (try? FileManager.default.contentsOfDirectory(
    at: tmpNotes.deletingLastPathComponent(), includingPropertiesForKeys: nil))?
    .contains { $0.lastPathComponent.hasPrefix("notes.json.corrupt-") } ?? false
check("corrupt file returns empty state", loaded == NotesData())
check("corrupt file quarantined (original preserved)",
      quarantined && !FileManager.default.fileExists(atPath: tmpNotes.path))
for f in (try? FileManager.default.contentsOfDirectory(at: tmpNotes.deletingLastPathComponent(),
    includingPropertiesForKeys: nil)) ?? [] where f.lastPathComponent.hasPrefix("notes.json.corrupt-") {
    try? FileManager.default.removeItem(at: f)
}
// 9d. hooksInstalled must survive JSONSerialization's slash escaping.
let tmpSettings2 = FileManager.default.temporaryDirectory
    .appendingPathComponent("cdash-settings2-\(UUID().uuidString).json")
try! JSONSerialization.data(withJSONObject: [String: Any]()).write(to: tmpSettings2)
_ = try? ClaudeCodeMonitor.installHooks(settingsURL: tmpSettings2)
check("hooksInstalled true on file we wrote (slash-escape proof)",
      ClaudeCodeMonitor.hooksInstalled(settingsURL: tmpSettings2))
try? FileManager.default.removeItem(at: tmpSettings2)
// 9e. Unparseable settings.json must ABORT install, not wipe the file.
let tmpBad = FileManager.default.temporaryDirectory
    .appendingPathComponent("cdash-bad-\(UUID().uuidString).json")
try! "not json at all".data(using: .utf8)!.write(to: tmpBad)
var threw = false
do { _ = try ClaudeCodeMonitor.installHooks(settingsURL: tmpBad) } catch { threw = true }
check("install aborts on unparseable settings", threw)
check("unparseable settings left untouched",
      (try? String(contentsOf: tmpBad, encoding: .utf8)) == "not json at all")
try? FileManager.default.removeItem(at: tmpBad)
// 9f. END-TO-END: the hook script must produce ONE parseable JSONL line from
// newline-terminated stdin (exactly what Claude Code sends).
let tmpSettings3 = FileManager.default.temporaryDirectory
    .appendingPathComponent("cdash-settings3-\(UUID().uuidString).json")
try! JSONSerialization.data(withJSONObject: [String: Any]()).write(to: tmpSettings3)
_ = try? ClaudeCodeMonitor.installHooks(settingsURL: tmpSettings3)   // also writes the script
// Run the script against an ISOLATED events dir — a previous version of this
// test wrote into the real events file and haunted the board with a phantom
// "test dir" session.
let isolatedDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("cdash-hookrun-\(UUID().uuidString)", isDirectory: true)
try! FileManager.default.createDirectory(at: isolatedDir, withIntermediateDirectories: true)
let prodEventsBefore = (try? Data(contentsOf: ClaudeCodeMonitor.eventsFile))?.count ?? -1
let hookRun = Process()
hookRun.executableURL = URL(fileURLWithPath: "/bin/bash")
hookRun.arguments = [ClaudeCodeMonitor.hookScript.path, "Notification"]
hookRun.environment = ProcessInfo.processInfo.environment
    .merging(["CLAUDE_DASH_DIR": isolatedDir.path]) { _, new in new }
let stdinPipe = Pipe()
hookRun.standardInput = stdinPipe
try! hookRun.run()
stdinPipe.fileHandleForWriting.write(Data("{\"session_id\":\"t1\",\"cwd\":\"/tmp/test dir\"}\n".utf8))
stdinPipe.fileHandleForWriting.closeFile()
hookRun.waitUntilExit()
let isolatedEvents = isolatedDir.appendingPathComponent("cc-events.jsonl")
let eventLines = ((try? String(contentsOf: isolatedEvents, encoding: .utf8)) ?? "")
    .components(separatedBy: "\n").filter { !$0.isEmpty }
check("hook run wrote exactly one line (isolated dir)", eventLines.count == 1)
if let last = eventLines.last, let d = last.data(using: .utf8),
   let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
    check("event line parses as JSON", obj["event"] as? String == "Notification")
    check("payload cwd intact", ((obj["payload"] as? [String: Any])?["cwd"] as? String) == "/tmp/test dir")
} else {
    check("hook event line is valid JSON", false)
}
let prodEventsAfter = (try? Data(contentsOf: ClaudeCodeMonitor.eventsFile))?.count ?? -1
check("REAL events file untouched by the test", prodEventsBefore == prodEventsAfter)
try? FileManager.default.removeItem(at: tmpSettings3)
try? FileManager.default.removeItem(at: isolatedDir)

print("== 8c. Claude Code owner matching (org uuid → account card) ==")
let ownerAccounts = [
    Account(id: "acct1", displayName: "Personal", orgUuid: "org-aaa", orgName: "Personal",
            chromeProfileDir: "Default", chromeProfileLabel: "x"),
    Account(id: "acct2", displayName: "Work", orgUuid: "org-bbb", orgName: "Work",
            chromeProfileDir: "Profile 1", chromeProfileLabel: "y"),
]
check("login org matches its account", matchCCOwner(loginOrgUuid: "org-bbb", accounts: ownerAccounts) == "acct2")
check("unknown org matches nothing", matchCCOwner(loginOrgUuid: "org-zzz", accounts: ownerAccounts) == nil)
check("nil login matches nothing", matchCCOwner(loginOrgUuid: nil, accounts: ownerAccounts) == nil)

print("== 11. Codex: window-label buckets (±5% tolerance, matches the client) ==")
check("300 → 5h", CodexMonitor.windowLabel(minutes: 300) == "5h")
check("1440 → daily", CodexMonitor.windowLabel(minutes: 1440) == "daily")
check("10080 → weekly", CodexMonitor.windowLabel(minutes: 10080) == "weekly")
check("43200 → monthly", CodexMonitor.windowLabel(minutes: 43200) == "monthly")
check("43800 (Team's ~30.4d) → monthly (in ±5% band)", CodexMonitor.windowLabel(minutes: 43800) == "monthly")
check("525600 → annual", CodexMonitor.windowLabel(minutes: 525600) == "annual")
check("odd value → usage", CodexMonitor.windowLabel(minutes: 999) == "usage")
check("nil window → usage", CodexMonitor.windowLabel(minutes: nil) == "usage")

print("== 11b. Codex: rate_limits → CodexUsage (Team single-monthly, verified shape) ==")
let teamRL: [String: Any] = [
    "limit_id": "codex",
    "primary": ["used_percent": 57.0, "window_minutes": 43800, "resets_at": 1785681569],
    "secondary": NSNull(),
    "plan_type": "team",
]
if let u = CodexMonitor.usage(fromRateLimits: teamRL, snapshotAt: Date(), email: "brian@heybaro.com", jwtPlan: nil) {
    check("one window (secondary null ignored)", u.windows.count == 1)
    check("labeled monthly", u.windows.first?.label == "monthly")
    check("utilization = 57", u.windows.first?.metric.utilization == 57)
    check("resets_at decoded to the right instant",
          u.windows.first?.metric.resetsAt == Date(timeIntervalSince1970: 1785681569))
    check("plan from snapshot", u.planType == "team")
    check("email carried through", u.accountEmail == "brian@heybaro.com")
} else { check("team usage decoded", false) }

print("== 11c. Codex: Plus-shape (5h primary + weekly secondary) ==")
let plusRL: [String: Any] = [
    "primary": ["used_percent": 20.0, "window_minutes": 300, "resets_at": 1785681569],
    "secondary": ["used_percent": 8.0, "window_minutes": 10080, "resets_at": 1785881569],
    "plan_type": "plus",
]
if let u = CodexMonitor.usage(fromRateLimits: plusRL, snapshotAt: Date(), email: nil, jwtPlan: nil) {
    check("two windows", u.windows.count == 2)
    check("labels 5h + weekly", u.windows.map(\.label) == ["5h", "weekly"])
} else { check("plus usage decoded", false) }

print("== 11d. Codex: reset fallbacks + plan/skip edge cases ==")
let snap = Date()
let relRL: [String: Any] = ["primary": ["used_percent": 10.0, "window_minutes": 300, "resets_in_seconds": 600]]
if let u = CodexMonitor.usage(fromRateLimits: relRL, snapshotAt: snap, email: nil, jwtPlan: "pro") {
    let reset = u.windows.first?.metric.resetsAt ?? .distantPast
    check("resets_in_seconds is relative to the snapshot", abs(reset.timeIntervalSince(snap) - 600) < 1)
    check("plan falls back to JWT when snapshot omits it", u.planType == "pro")
} else { check("relative-reset usage decoded", false) }
check("no windows at all → nil", CodexMonitor.usage(fromRateLimits: ["plan_type": "team"], snapshotAt: snap, email: nil, jwtPlan: nil) == nil)
check("window missing used_percent is skipped → nil",
      CodexMonitor.usage(fromRateLimits: ["primary": ["window_minutes": 300]], snapshotAt: snap, email: nil, jwtPlan: nil) == nil)

print("== 11e. Codex: JWT claim decode + account label (no secrets read out) ==")
func makeJWT(_ payload: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: payload)
    let b64url = data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "eyJhbGciOiJub25lIn0.\(b64url).sig"   // header.payload.signature
}
let jwt = makeJWT([
    "email": "brian@heybaro.com",
    "https://api.openai.com/auth": ["chatgpt_plan_type": "team", "chatgpt_account_id": "acct-1"],
])
if let claims = CodexMonitor.decodeJWTClaims(jwt) {
    check("email claim decoded", claims["email"] as? String == "brian@heybaro.com")
} else { check("JWT claims decoded", false) }
let tmpAuth = FileManager.default.temporaryDirectory
    .appendingPathComponent("cdash-auth-\(UUID().uuidString).json")
try! JSONSerialization.data(withJSONObject: ["tokens": ["id_token": jwt]]).write(to: tmpAuth)
let label = CodexMonitor.accountLabel(authURL: tmpAuth)
check("account label email from auth.json JWT", label.email == "brian@heybaro.com")
check("account label plan from auth.json JWT", label.plan == "team")
check("missing auth.json → empty label (no crash)",
      CodexMonitor.accountLabel(authURL: tmpAuth.appendingPathExtension("nope")).email == nil)
try? FileManager.default.removeItem(at: tmpAuth)

print("== 11f. Codex: latest token_count from rollout JSONL (tail + fall-through) ==")
let tmpDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("cdash-codex-\(UUID().uuidString)", isDirectory: true)
try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
// A file with NO token_count (should be skipped) …
let emptyRollout = tmpDir.appendingPathComponent("rollout-empty.jsonl")
try! #"{"type":"response_item","payload":{"type":"message"}}"#.write(to: emptyRollout, atomically: true, encoding: .utf8)
// … and a file whose LAST token_count is the one we want (an earlier 30% must lose).
let goodRollout = tmpDir.appendingPathComponent("rollout-good.jsonl")
try! """
{"timestamp":"2026-07-08T19:00:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":30.0,"window_minutes":43800,"resets_at":1785681569}}}}
not-json
{"timestamp":"2026-07-08T19:46:56.323Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":57.0,"window_minutes":43800,"resets_at":1785681569},"plan_type":"team"}}}
{"type":"response_item","payload":{"type":"message"}}
""".write(to: goodRollout, atomically: true, encoding: .utf8)
if let (rl, at) = CodexMonitor.latestTokenCount(in: [emptyRollout, goodRollout]) {
    let primary = rl["primary"] as? [String: Any]
    check("skips the token_count-less file and finds the next", (primary?["used_percent"] as? NSNumber)?.doubleValue == 57.0)
    check("uses the LAST token_count in the file (57, not the earlier 30)", (primary?["used_percent"] as? NSNumber)?.doubleValue == 57.0)
    let expectedTS: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    let expected = expectedTS.date(from: "2026-07-08T19:46:56.323Z")!
    check("snapshot timestamp parsed from the event line, not file mtime", abs(at.timeIntervalSince(expected)) < 2)
} else { check("latestTokenCount found a snapshot", false) }
check("no files → nil", CodexMonitor.latestTokenCount(in: []) == nil)
try? FileManager.default.removeItem(at: tmpDir)

print("== 11g. Codex: account-switch label guard (auth.json newer than snapshot ⇒ drop email) ==")
let t0 = Date()
check("auth written before the snapshot → trust the label",
      CodexMonitor.labelAppliesToSnapshot(authModified: t0.addingTimeInterval(-60), snapshotAt: t0))
check("auth rewritten AFTER the snapshot (login switch) → suppress the label",
      !CodexMonitor.labelAppliesToSnapshot(authModified: t0.addingTimeInterval(60), snapshotAt: t0))
check("no auth mtime available → trust (best effort, no crash)",
      CodexMonitor.labelAppliesToSnapshot(authModified: nil, snapshotAt: t0))

print("== 10. LIVE claude.ai endpoint — invalid key must map to .unauthorized ==")
if onCI {
    print("  SKIP  (datacenter IPs may be WAF-blocked; run locally)")
    print("\n== RESULT: \(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)") ==")
    exit(failures == 0 ? 0 : 1)
}
let sema = DispatchSemaphore(value: 0)
Task {
    do {
        _ = try await UsageAPI.organizations(sessionKey: "sk-ant-sid01-invalid-key-for-testing-only")
        check("invalid key should NOT succeed", false)
    } catch let e as UsageError {
        print("        server responded with: \(e.display)")
        // Any clean mapped error proves the request reached the server and was handled.
        // .unauthorized is expected; .rateLimited or http(x) also prove the path works (not a crash/hang).
        check("mapped to a clean UsageError (path + headers + error handling work)", true)
        check("specifically .unauthorized (401/403)", e == .unauthorized)
    } catch {
        check("unexpected non-UsageError: \(error)", false)
    }
    sema.signal()
}
if sema.wait(timeout: .now() + 20) == .timedOut {
    check("live endpoint responded within 20s", false)
}

print("\n== RESULT: \(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)") ==")
exit(failures == 0 ? 0 : 1)
