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
