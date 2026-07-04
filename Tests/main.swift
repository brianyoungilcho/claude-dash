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

print("== 3. Chrome profile discovery (real Local State) ==")
let profiles = ChromeProfiles.all()
check("found at least one Chrome profile", profiles.count > 0)
print("        discovered \(profiles.count) profiles:")
for p in profiles { print("          [\(p.dir)] \(p.label)") }

print("== 4. Keychain round-trip ==")
let testAccount = "test-\(UUID().uuidString)"
let secret = "sk-ant-sid01-test-value-\(Int.random(in: 1000...9999))"
check("store succeeds", Keychain.set(secret, account: testAccount))
check("read matches", Keychain.get(account: testAccount) == secret)
Keychain.delete(account: testAccount)
check("delete removes it", Keychain.get(account: testAccount) == nil)

print("== 5. LIVE claude.ai endpoint — invalid key must map to .unauthorized ==")
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
_ = sema.wait(timeout: .now() + 20)

print("\n== RESULT: \(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)") ==")
exit(failures == 0 ? 0 : 1)
