import Foundation
import Security

// MARK: - Models

/// One usage metric (a 5-hour session window or a 7-day window).
struct UsageMetric: Equatable {
    var utilization: Double   // 0...100, already a percentage
    var resetsAt: Date?
}

/// A per-model (or per-surface) scoped limit, e.g. the Fable weekly cap.
struct ScopedMetric: Equatable {
    var name: String        // display name from the API, e.g. "Fable"
    var metric: UsageMetric
}

/// Paid extra-usage / overage state (only rendered when enabled on the account).
struct ExtraUsage: Equatable {
    var percent: Double
    var usedDisplay: String?    // e.g. "$3.50 used"
}

/// A snapshot of an account's usage at a point in time.
struct AccountUsage: Equatable {
    var session: UsageMetric?       // rolling 5-hour window
    var weekly: UsageMetric?        // 7-day, all models
    var scoped: [ScopedMetric] = [] // per-model weekly caps (Fable, …)
    var extra: ExtraUsage?          // overage credits, when enabled
    var fetchedAt: Date
    /// Projected moment the session cap is hit at the current burn rate,
    /// set by the model when it has two samples to compare. Only meaningful
    /// (and only shown) when it lands before the session reset.
    var projectedCap: Date?
}

/// The live state of a single account's usage fetch.
enum UsageState: Equatable {
    case unknown
    case loading
    case ok(AccountUsage)
    case unauthorized      // expired / invalid session key
    case rateLimited
    case error(String)
}

/// A configured account. Non-secret; the session key lives in the Keychain, keyed by `id`.
struct Account: Codable, Identifiable, Equatable {
    var id: String            // UUID string; also the Keychain account name
    var displayName: String
    var orgUuid: String
    var orgName: String
    var chromeProfileDir: String
    var chromeProfileLabel: String   // profile name / email, for display only
}

/// An organization discovered for a session key.
struct Org: Identifiable, Equatable, Hashable {
    var uuid: String
    var name: String
    var capabilities: [String] = []
    var id: String { uuid }
    /// API/console orgs appear in the org list but don't serve chat usage.
    var isChatOrg: Bool { capabilities.isEmpty || capabilities.contains("chat") }
}

/// A recent claude.ai conversation on an account (board "signals" layer).
struct Convo: Equatable, Identifiable {
    var uuid: String
    var name: String
    var updatedAt: Date?
    var model: String?
    var id: String { uuid }
}

enum UsageError: Error, Equatable {
    case unauthorized
    case rateLimited
    case noOrganizations
    case network(String)
    case decoding(String)
    case http(Int)

    var display: String {
        switch self {
        case .unauthorized:   return "Session key expired or invalid"
        case .rateLimited:    return "Rate limited — try again shortly"
        case .noOrganizations:return "No organizations for this key"
        case .network(let m): return "Network error: \(m)"
        case .decoding(let m):return "Unexpected response: \(m)"
        case .http(let c):    return "HTTP \(c)"
        }
    }
}

// MARK: - Keychain (session keys never touch disk in cleartext)
//
// Storage goes through /usr/bin/security rather than the SecItem API on purpose:
// this app is ad-hoc signed, so every rebuild is a "different app" to the
// Keychain ACL and direct SecItem reads trigger a password prompt after each
// rebuild. Items created and read by Apple's signed `security` tool have a
// stable accessor identity, so no prompts — same model Claude Code itself uses
// for its credentials.

enum Keychain {
    static let service = "com.claudedash.sessionkey"

    /// Run `security` with the given interactive-mode command fed via stdin
    /// (keeps secrets out of `ps`-visible argv). Returns (exitCode, stdout).
    @discardableResult
    private static func security(stdinCommand: String? = nil, args: [String] = []) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        if let cmd = stdinCommand {
            p.arguments = ["-i"]
            let inPipe = Pipe()
            p.standardInput = inPipe
            do { try p.run() } catch { return (-1, "") }
            inPipe.fileHandleForWriting.write(Data((cmd + "\n").utf8))
            inPipe.fileHandleForWriting.closeFile()
        } else {
            p.arguments = args
            do { try p.run() } catch { return (-1, "") }
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    @discardableResult
    static func set(_ value: String, account: String) -> Bool {
        // -U updates in place if the item exists. Interactive mode keeps the
        // secret out of the process argument list. Verify with a read-back.
        security(stdinCommand: #"add-generic-password -U -s "\#(service)" -a "\#(account)" -w "\#(value)""#)
        return get(account: account) == value
    }

    static func get(account: String) -> String? {
        let (code, out) = security(args: ["find-generic-password", "-s", service, "-a", account, "-w"])
        guard code == 0 else { return nil }
        let value = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func delete(account: String) {
        security(args: ["delete-generic-password", "-s", service, "-a", account])
    }
}

// MARK: - Chrome profile discovery (reads Local State; only profile names/emails)

struct ChromeProfile: Identifiable, Equatable, Hashable {
    var dir: String       // e.g. "Profile 1", "Default"
    var name: String
    var email: String
    var id: String { dir }
    var label: String { email.isEmpty ? name : "\(name) — \(email)" }
}

/// A Chromium-family browser: display/app name plus its profile-data location.
struct Browser: Equatable {
    let appName: String        // name passed to `open -na`
    let supportSubpath: String // under ~/Library/Application Support
}

enum BrowserDetect {
    static let candidates = [
        Browser(appName: "Google Chrome", supportSubpath: "Google/Chrome"),
        Browser(appName: "Brave Browser", supportSubpath: "BraveSoftware/Brave-Browser"),
        Browser(appName: "Microsoft Edge", supportSubpath: "Microsoft Edge"),
        Browser(appName: "Chromium", supportSubpath: "Chromium"),
    ]

    static func localState(for b: Browser) -> String {
        NSString(string: "~/Library/Application Support/\(b.supportSubpath)/Local State").expandingTildeInPath
    }

    /// First browser with profile data on disk; Chrome wins ties. Overridable:
    ///   defaults write com.claudedash.app browserAppName "Brave Browser"
    ///   defaults write com.claudedash.app browserSupportSubpath "BraveSoftware/Brave-Browser"
    static func current() -> Browser {
        let d = UserDefaults.standard
        if let app = d.string(forKey: "browserAppName"),
           let sub = d.string(forKey: "browserSupportSubpath") {
            return Browser(appName: app, supportSubpath: sub)
        }
        for c in candidates where FileManager.default.fileExists(atPath: localState(for: c)) {
            return c
        }
        return candidates[0]
    }
}

enum ChromeProfiles {
    static var localStatePath: String { BrowserDetect.localState(for: BrowserDetect.current()) }

    static func all() -> [ChromeProfile] {
        guard let data = FileManager.default.contents(atPath: localStatePath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = json["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: Any] else { return [] }
        var rows: [ChromeProfile] = []
        for (dir, v) in cache {
            if dir == "Guest Profile" || dir == "System Profile" { continue }
            let info = v as? [String: Any] ?? [:]
            let name = (info["name"] as? String ?? dir).trimmingCharacters(in: .whitespaces)
            let email = (info["user_name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            rows.append(ChromeProfile(dir: dir, name: name, email: email))
        }
        return rows.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }
}

// MARK: - Usage API (mirrors Claude-Usage-Tracker v3.1.1's claude.ai flow)

enum UsageAPI {
    private static let base = "https://claude.ai/api"
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    // Dedicated ephemeral session: never persist or accept cookies, so per-account
    // session keys can't leak into one another.
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.httpCookieStorage = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 30
        return URLSession(configuration: c)
    }()

    private static func request(_ path: String, sessionKey: String) -> URLRequest {
        var r = URLRequest(url: URL(string: base + path)!)
        r.httpMethod = "GET"
        r.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue("https://claude.ai", forHTTPHeaderField: "Referer")
        r.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
        return r
    }

    private static func run(_ req: URLRequest) async throws -> Data {
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) }
        catch { throw UsageError.network(error.localizedDescription) }
        guard let http = resp as? HTTPURLResponse else { throw UsageError.network("no response") }
        switch http.statusCode {
        case 200: return data
        case 401, 403: throw UsageError.unauthorized
        case 429: throw UsageError.rateLimited
        default: throw UsageError.http(http.statusCode)
        }
    }

    /// Validate a key and list its organizations.
    static func organizations(sessionKey: String) async throws -> [Org] {
        let data = try await run(request("/organizations", sessionKey: sessionKey))
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw UsageError.decoding("organizations")
        }
        let orgs = arr.compactMap { o -> Org? in
            guard let uuid = o["uuid"] as? String else { return nil }
            let name = (o["name"] as? String) ?? uuid
            let caps = (o["capabilities"] as? [String]) ?? []
            return Org(uuid: uuid, name: name, capabilities: caps)
        }
        if orgs.isEmpty { throw UsageError.noOrganizations }
        // Chat orgs first — they're the ones whose usage we can actually read.
        return orgs.sorted { $0.isChatOrg && !$1.isChatOrg }
    }

    /// Most recent conversations for one organization (title + freshness only).
    static func conversations(sessionKey: String, orgUuid: String, limit: Int = 20) async throws -> [Convo] {
        let data = try await run(request("/organizations/\(orgUuid)/chat_conversations?limit=\(limit)",
                                         sessionKey: sessionKey))
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw UsageError.decoding("conversations")
        }
        return decodeConversations(arr)
    }

    /// Only FRESH conversations are signal — stale ones read as noise (heavy
    /// Claude Code use burns quota without creating web chats, so days-old
    /// titles would sit there looking broken). Sort defensively (the API is
    /// recency-ordered today, but don't depend on it), keep ≤48h, cap at 3.
    static func recentConvos(_ list: [Convo], now: Date = Date()) -> [Convo] {
        let cutoff = now.addingTimeInterval(-48 * 3600)
        return list
            .filter { ($0.updatedAt ?? .distantPast) > cutoff }
            .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
            .prefix(3).map { $0 }
    }

    /// Internal so it can be unit-tested against captured fixtures.
    static func decodeConversations(_ arr: [[String: Any]]) -> [Convo] {
        arr.compactMap { c in
            guard let uuid = c["uuid"] as? String else { return nil }
            return Convo(uuid: uuid,
                         name: (c["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled",
                         updatedAt: (c["updated_at"] as? String).flatMap(date),
                         model: c["model"] as? String)
        }
    }

    /// Fetch the 5-hour + 7-day usage for one organization.
    static func usage(sessionKey: String, orgUuid: String) async throws -> AccountUsage {
        let data = try await run(request("/organizations/\(orgUuid)/usage", sessionKey: sessionKey))
        guard let u = decodeUsage(data) else { throw UsageError.decoding("usage") }
        return u
    }

    /// Decode the usage endpoint's JSON body. Internal so it can be unit-tested.
    ///
    /// Primary source is the modern `limits[]` array (kind: session / weekly_all /
    /// weekly_scoped with a per-model scope). The legacy `five_hour` / `seven_day`
    /// objects are the fallback for older response shapes.
    static func decodeUsage(_ data: Data) -> AccountUsage? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var usage = AccountUsage(fetchedAt: Date())

        for l in (obj["limits"] as? [[String: Any]]) ?? [] {
            guard let pct = number(l["percent"]) else { continue }
            let m = UsageMetric(utilization: pct,
                                resetsAt: (l["resets_at"] as? String).flatMap(date))
            switch l["kind"] as? String {
            case "session":
                usage.session = m
            case "weekly_all":
                usage.weekly = m
            case "weekly_scoped":
                let scope = l["scope"] as? [String: Any]
                let model = scope?["model"] as? [String: Any]
                let name = (model?["display_name"] as? String) ?? "Model"
                usage.scoped.append(ScopedMetric(name: name, metric: m))
            default:
                break
            }
        }

        if usage.session == nil { usage.session = metric(obj["five_hour"]) }
        if usage.weekly == nil { usage.weekly = metric(obj["seven_day"]) }
        usage.extra = extraUsage(obj)
        guard usage.session != nil || usage.weekly != nil || !usage.scoped.isEmpty else { return nil }
        return usage
    }

    /// Overage credits: prefer the modern `spend` object, fall back to `extra_usage`.
    private static func extraUsage(_ obj: [String: Any]) -> ExtraUsage? {
        if let spend = obj["spend"] as? [String: Any], spend["enabled"] as? Bool == true {
            let pct = number(spend["percent"]) ?? 0
            var display: String?
            if let used = spend["used"] as? [String: Any],
               let minor = number(used["amount_minor"]) {
                let exponent = number(used["exponent"]) ?? 2
                let currency = (used["currency"] as? String) ?? "USD"
                display = String(format: "%.2f %@ used", minor / pow(10, exponent), currency)
            }
            return ExtraUsage(percent: pct, usedDisplay: display)
        }
        if let extra = obj["extra_usage"] as? [String: Any], extra["is_enabled"] as? Bool == true {
            let pct = number(extra["utilization"]) ?? 0
            var display: String?
            if let used = number(extra["used_credits"]) {
                display = String(format: "%.2f used", used)
            }
            return ExtraUsage(percent: pct, usedDisplay: display)
        }
        return nil
    }

    private static func metric(_ any: Any?) -> UsageMetric? {
        guard let d = any as? [String: Any] else { return nil }
        let util = number(d["utilization"]) ?? 0
        let reset = (d["resets_at"] as? String).flatMap(date)
        return UsageMetric(utilization: util, resetsAt: reset)
    }

    private static func number(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    private static func date(_ s: String) -> Date? { isoFrac.date(from: s) ?? iso.date(from: s) }
}
