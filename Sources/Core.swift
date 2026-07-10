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

extension UsageMetric {
    /// At (or past) the hard limit. Matches the used-% label, which truncates,
    /// so only >= 100 displays "100%". (The optional remaining-% label rounds
    /// and can read "0% left" a hair early — the dim keys off the real cap,
    /// not that rounding.)
    var isCapped: Bool { utilization >= 100 }
}

extension AccountUsage {
    /// Some limit window (session, weekly, or a per-model cap) is exhausted,
    /// so the card is de-emphasized. A scoped cap only blocks that one model,
    /// but it still merits the dim — the dashboard's job is routing attention
    /// to accounts with headroom. Extra-usage spend is excluded: it's a budget
    /// meter, not a lockout.
    var anyLimitCapped: Bool {
        ([session, weekly].compactMap { $0 } + scoped.map(\.metric))
            .contains(where: \.isCapped)
    }
}

/// The live state of a single account's usage fetch. A last-known snapshot and
/// a problem deliberately coexist: an upstream hiccup must not erase useful
/// numbers or masquerade as a dead credential.
enum UsageState: Equatable {
    case unknown
    case loading
    case ok(AccountUsage)
    case stale(AccountUsage, UsageProblem)
    case problem(UsageProblem)

    var snapshot: AccountUsage? {
        switch self {
        case .ok(let usage), .stale(let usage, _): return usage
        case .unknown, .loading, .problem: return nil
        }
    }

    var usageProblem: UsageProblem? {
        switch self {
        case .stale(_, let problem), .problem(let problem): return problem
        case .unknown, .loading, .ok: return nil
        }
    }
}

enum NetworkProblem: Equatable {
    case offline
    case timedOut
    case cancelled
    case other
}

/// Recovery-oriented problems shown by the dashboard. These never contain a
/// session key, raw response body, or a server-supplied error string.
enum UsageProblem: Equatable {
    case credentialUnavailable
    case keychainUnavailable
    case signInCheck
    case signInRequired
    case accessDenied
    case rateLimited(Date?)
    case temporary(status: Int?)
    case network(NetworkProblem)
    case responseChanged(status: Int?)
    case noOrganizations

    var needsSignIn: Bool { self == .signInRequired || self == .credentialUnavailable }

    var isTransient: Bool {
        switch self {
        case .signInCheck, .rateLimited, .temporary, .network: return true
        case .credentialUnavailable, .keychainUnavailable, .signInRequired,
             .accessDenied, .responseChanged, .noOrganizations: return false
        }
    }

    var display: String {
        switch self {
        case .credentialUnavailable: return "Stored sign-in unavailable"
        case .keychainUnavailable: return "Couldn't read the macOS Keychain"
        case .signInCheck: return "Claude couldn't verify this sign-in — retrying"
        case .signInRequired: return "Claude sign-in needs attention"
        case .accessDenied: return "Claude denied this usage request — this may be temporary"
        case .rateLimited(let retryAt):
            guard let retryAt else { return "Usage checks are rate limited — retrying soon" }
            return "Usage checks are rate limited — retrying \(retryAt.formatted(date: .omitted, time: .shortened))"
        case .temporary: return "Claude usage is temporarily unavailable"
        case .network(.offline): return "Can't reach Claude — check your connection"
        case .network(.timedOut): return "Claude usage request timed out"
        case .network(.cancelled): return "Claude usage request was cancelled"
        case .network(.other): return "Can't reach Claude right now"
        case .responseChanged: return "Claude's usage response changed — check for an app update"
        case .noOrganizations: return "No Claude workspace was found for this sign-in"
        }
    }
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

/// Which board account owns the Claude Code login's organization? Pure so
/// it's unit-testable without the UI layer.
func matchCCOwner(loginOrgUuid: String?, accounts: [Account]) -> String? {
    guard let loginOrgUuid else { return nil }
    return accounts.first { $0.orgUuid == loginOrgUuid }?.id
}

/// Footer "Updated …" text + whether it's gone stale (older than 2 poll cycles).
/// Pure so it's unit-testable without the UI layer.
func updatedLabel(_ date: Date?, pollInterval: TimeInterval, now: Date = Date()) -> (text: String, stale: Bool)? {
    guard let date else { return nil }
    let age = now.timeIntervalSince(date)
    let stale = age > max(120, 2 * pollInterval)
    if age < 90 { return (stale ? "Updated just now" : "Updated \(date.formatted(date: .omitted, time: .shortened))", stale) }
    let mins = Int(age) / 60
    if mins < 60 { return ("Updated \(mins)m ago", stale) }
    let hrs = mins / 60
    if hrs < 24 { return ("Updated \(hrs)h ago", stale) }
    return ("Updated \(date.formatted(date: .abbreviated, time: .shortened))", stale)
}

enum UsageError: Error, Equatable {
    case signInRequired
    case accessDenied
    case rateLimited(Date?)
    case temporary(status: Int?)
    case network(NetworkProblem)
    case responseChanged(status: Int?)
    case noOrganizations

    var problem: UsageProblem {
        switch self {
        case .signInRequired: return .signInRequired
        case .accessDenied: return .accessDenied
        case .rateLimited(let retryAt): return .rateLimited(retryAt)
        case .temporary(let status): return .temporary(status: status)
        case .network(let problem): return .network(problem)
        case .responseChanged(let status): return .responseChanged(status: status)
        case .noOrganizations: return .noOrganizations
        }
    }

    var display: String { problem.display }
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

    enum ReadResult: Equatable {
        case value(String)
        case missing
        case unavailable
    }

    /// Run `security` with the given interactive-mode command fed via stdin
    /// (keeps secrets out of `ps`-visible argv). Returns (exitCode, stdout).
    @discardableResult
    private static func security(stdinCommand: String? = nil, args: [String] = []) -> (Int32, String, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        if let cmd = stdinCommand {
            p.arguments = ["-i"]
            let inPipe = Pipe()
            p.standardInput = inPipe
            do { try p.run() } catch { return (-1, "", "") }
            inPipe.fileHandleForWriting.write(Data((cmd + "\n").utf8))
            inPipe.fileHandleForWriting.closeFile()
        } else {
            p.arguments = args
            do { try p.run() } catch { return (-1, "", "") }
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let error = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus,
                String(data: data, encoding: .utf8) ?? "",
                String(data: error, encoding: .utf8) ?? "")
    }

    @discardableResult
    static func set(_ value: String, account: String) -> Bool {
        // -U updates in place if the item exists. Interactive mode keeps the
        // secret out of the process argument list. Verify with a read-back.
        security(stdinCommand: #"add-generic-password -U -s "\#(service)" -a "\#(account)" -w "\#(value)""#)
        return get(account: account) == value
    }

    /// Distinguishes an absent item from a Keychain/tool failure. `security`
    /// reports errSecItemNotFound as shell status 44 on current macOS; the
    /// stderr fallback keeps this tolerant of wording/status changes.
    static func read(account: String) -> ReadResult {
        let (code, out, err) = security(args: ["find-generic-password", "-s", service, "-a", account, "-w"])
        if code == 0 {
            let value = out.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? .missing : .value(value)
        }
        let lower = err.lowercased()
        if code == 44 || lower.contains("could not be found") || lower.contains("item not found") {
            return .missing
        }
        return .unavailable
    }

    static func get(account: String) -> String? {
        if case .value(let value) = read(account: account) { return value }
        return nil
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
        catch let error as URLError { throw UsageError.network(networkProblem(error)) }
        catch { throw UsageError.network(.other) }
        guard let http = resp as? HTTPURLResponse else { throw UsageError.network(.other) }
        guard http.statusCode != 200 else { return data }
        throw classifyHTTP(statusCode: http.statusCode,
                           headers: headers(from: http),
                           body: data)
    }

    /// Pure classification so fixtures can cover the unofficial endpoint without
    /// putting a real session key on the network. Never returns raw server text.
    static func classifyHTTP(statusCode: Int, headers: [String: String], body: Data,
                             now: Date = Date()) -> UsageError {
        let contentType = headers.first { $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value.lowercased() ?? ""
        let server = headers.first { $0.key.caseInsensitiveCompare("Server") == .orderedSame }?.value.lowercased() ?? ""
        switch statusCode {
        case 401:
            return .signInRequired
        case 403:
            // A known invalid session currently returns JSON
            // {error:{type:permission_error,message:"Invalid authorization"}}.
            // Other 403s can be workspace, policy, WAF, or service failures.
            if isExplicitInvalidAuthorization(body) { return .signInRequired }
            if contentType.contains("text/html") || server.contains("cloudflare") {
                return .temporary(status: statusCode)
            }
            return .accessDenied
        case 429:
            let retry = headers.first { $0.key.caseInsensitiveCompare("Retry-After") == .orderedSame }?.value
            return .rateLimited(retryAfter(retry, now: now))
        case 408, 500...599:
            return .temporary(status: statusCode)
        case 404:
            return .accessDenied
        case 400, 402, 405...499:
            return .responseChanged(status: statusCode)
        default:
            return .responseChanged(status: statusCode)
        }
    }

    private static func headers(from response: HTTPURLResponse) -> [String: String] {
        response.allHeaderFields.reduce(into: [:]) { result, pair in
            guard let key = pair.key as? String else { return }
            result[key] = String(describing: pair.value)
        }
    }

    private static func isExplicitInvalidAuthorization(_ data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = root["error"] as? [String: Any],
              (error["type"] as? String)?.lowercased() == "permission_error",
              let message = error["message"] as? String else { return false }
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "invalid authorization" || normalized == "invalid session" || normalized == "not authenticated"
    }

    private static func retryAfter(_ header: String?, now: Date) -> Date? {
        guard let header = header?.trimmingCharacters(in: .whitespacesAndNewlines), !header.isEmpty else { return nil }
        if let seconds = TimeInterval(header) { return now.addingTimeInterval(max(0, seconds)) }
        return httpDate.date(from: header)
    }

    private static func networkProblem(_ error: URLError) -> NetworkProblem {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return .offline
        case .timedOut: return .timedOut
        case .cancelled: return .cancelled
        default: return .other
        }
    }

    /// Validate a key and list its organizations.
    static func organizations(sessionKey: String) async throws -> [Org] {
        let data = try await run(request("/organizations", sessionKey: sessionKey))
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw UsageError.responseChanged(status: nil)
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

    /// Fetch the 5-hour + 7-day usage for one organization.
    static func usage(sessionKey: String, orgUuid: String) async throws -> AccountUsage {
        let data = try await run(request("/organizations/\(orgUuid)/usage", sessionKey: sessionKey))
        guard let u = decodeUsage(data) else { throw UsageError.responseChanged(status: nil) }
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
    private static let httpDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        return f
    }()
    private static func date(_ s: String) -> Date? { isoFrac.date(from: s) ?? iso.date(from: s) }
}
