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

print("== 5. Conversations decode (fixture captured live 2026-07-06) ==")
let convoFixture: [[String: Any]] = [
    ["uuid": "abc-123", "name": "타이어가 파여있는 꿈의 의미", "updated_at": "2026-07-03T11:27:26.024683Z",
     "model": "claude-fable-5", "is_starred": false, "platform": "web"],
    ["uuid": "def-456", "name": "", "updated_at": "2026-07-01T00:00:00.000000Z"],
    ["name": "no uuid — must be skipped"],
]
let convos = UsageAPI.decodeConversations(convoFixture)
check("two valid conversations decoded", convos.count == 2)
check("korean title preserved", convos.first?.name.hasPrefix("타이어") == true)
check("updated_at parsed", convos.first?.updatedAt != nil)
check("empty name becomes Untitled", convos.dropFirst().first?.name == "Untitled")

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

print("== 8. Claude Code: project-dir naming + hooks merge (temp fixture) ==")
check("project dir display name", ClaudeCodeMonitor.displayName(forProjectDir: "-Users-alice-Desktop-Repo") == "Repo")
check("path encoding mirrors CC", ClaudeCodeMonitor.encodeProjectPath("/Users/alice/my.app") == "-Users-alice-my-app")
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

print("== 9. LIVE claude.ai endpoint — invalid key must map to .unauthorized ==")
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
