import Foundation
import CryptoKit

/// Local Codex usage awareness — pure file reading, nothing leaves the machine.
///
/// Codex writes a rate-limit snapshot after a turn, but those JSONL events do
/// not contain a stable account id. `auth.json` identifies only the account
/// currently signed in. Multi-account tracking therefore has one important
/// safety rule: after an auth change, Dash accepts a snapshot only from a
/// rollout file CREATED after that auth change. In practice this means making
/// one new Codex task and sending one prompt after switching accounts. It is
/// deliberately preferable to show a pending card over assigning old usage to
/// the wrong account.

/// One Codex usage window (the 5-hour, weekly, or monthly limit, per plan).
struct CodexWindow: Equatable {
    var label: String        // "5h", "weekly", "monthly", … (see windowLabel)
    var metric: UsageMetric  // utilization % + reset time — reuses the Claude type

    /// Capped only while the reset is still ahead. Codex snapshots go stale
    /// between turns (nothing rewrites them at reset time), so a 100% window
    /// whose reset already passed must not keep the card dimmed.
    func isCurrentlyCapped(now: Date = Date()) -> Bool {
        metric.isCapped && !(metric.resetsAt.map { $0 <= now } ?? false)
    }
}

/// A snapshot of one Codex account's usage, read from local rollout files.
/// Fields are stable across reads so an unchanged snapshot compares equal and
/// does not republish every poll — freshness is derived in the view.
struct CodexUsage: Equatable {
    var windows: [CodexWindow]
    var planType: String?
    var accountEmail: String?
    var snapshotAt: Date

    /// A local rollout snapshot is not a live counter. It becomes stale after
    /// an hour, or immediately after one of its reset windows has elapsed.
    func isStale(now: Date = Date(), maximumAge: TimeInterval = 3600) -> Bool {
        now.timeIntervalSince(snapshotAt) > maximumAge
            || windows.contains { $0.metric.resetsAt.map { $0 <= now } ?? false }
    }
}

/// Non-secret identity metadata decoded from the CURRENT `auth.json` JWT.
/// `accountKey` is a truncated SHA-256 digest of `chatgpt_account_id`; the raw
/// account id and JWT never leave the process or reach persistent storage.
struct CodexIdentity: Equatable {
    var accountKey: String
    var email: String?
    var planType: String?
    var authModifiedAt: Date?
}

/// A rollout snapshot plus only the timestamp metadata needed to attribute it
/// safely. The source path itself is intentionally never persisted.
struct CodexReading: Equatable {
    var usage: CodexUsage
    var sourceCreatedAt: Date?
    var sourceModifiedAt: Date?

    /// Event timestamp wins over rollout file mtime. A session can receive a
    /// late write long after a newer session has already recorded a reading.
    static func newest(in readings: [CodexReading]) -> CodexReading? {
        readings.max { lhs, rhs in
            if lhs.usage.snapshotAt != rhs.usage.snapshotAt {
                return lhs.usage.snapshotAt < rhs.usage.snapshotAt
            }
            return (lhs.sourceModifiedAt ?? .distantPast) < (rhs.sourceModifiedAt ?? .distantPast)
        }
    }
}

/// An identity/snapshot observation captured with an auth-file stability check.
/// When `isStable` is false, the app does not mutate its account cache.
struct CodexObservation: Equatable {
    var identity: CodexIdentity?
    var reading: CodexReading?
    var isStable: Bool
    /// One latest token-count candidate per recent rollout file, ordered by
    /// file mtime. The registry can skip an old-session candidate and still
    /// accept a safe fresh task in the same refresh.
    var additionalReadings: [CodexReading]

    init(identity: CodexIdentity?,
         reading: CodexReading?,
         isStable: Bool,
         additionalReadings: [CodexReading] = []) {
        self.identity = identity
        self.reading = reading
        self.isStable = isStable
        self.additionalReadings = additionalReadings
    }

    var readings: [CodexReading] { (reading.map { [$0] } ?? []) + additionalReadings }
}

// MARK: - Persisted, identity-keyed account cache (no credentials)

struct CodexCachedWindow: Codable, Equatable {
    var label: String
    var utilization: Double
    var resetsAt: Date?

    init(_ window: CodexWindow) {
        label = window.label
        utilization = window.metric.utilization
        resetsAt = window.metric.resetsAt
    }

    var window: CodexWindow {
        CodexWindow(label: label, metric: UsageMetric(utilization: utilization, resetsAt: resetsAt))
    }
}

/// Codable representation kept separate from `UsageMetric` so this local cache
/// remains self-contained and never changes Claude's live API model.
struct CodexCachedUsage: Codable, Equatable {
    var windows: [CodexCachedWindow]
    var planType: String?
    var snapshotAt: Date

    init(_ usage: CodexUsage) {
        windows = usage.windows.map(CodexCachedWindow.init)
        planType = usage.planType
        snapshotAt = usage.snapshotAt
    }

    func usage(email: String?, fallbackPlan: String?) -> CodexUsage {
        CodexUsage(windows: windows.map(\.window),
                   planType: planType ?? fallbackPlan,
                   accountEmail: email,
                   snapshotAt: snapshotAt)
    }
}

/// One remembered Codex identity. It contains display metadata and the last
/// attributable local snapshot only — never OAuth tokens or raw account ids.
struct CodexAccount: Codable, Equatable, Identifiable {
    var id: String                     // local SHA-256-derived account key
    var nickname: String?
    var email: String?
    var planType: String?
    var snapshot: CodexCachedUsage?
    /// Non-nil means Dash needs a fresh, post-switch rollout before assigning
    /// any current-session numbers to this account.
    var captureAfter: Date?
    /// Even after a fresh snapshot has been captured, keep rejecting events
    /// from rollout files created before the most recent identity fence. An old
    /// Team task can otherwise append late and overwrite Personal later on.
    var sourceCreatedAfter: Date?
    var firstSeenAt: Date
    var lastCapturedAt: Date?

    init(id: String,
         nickname: String? = nil,
         email: String? = nil,
         planType: String? = nil,
         usage: CodexUsage? = nil,
         captureAfter: Date? = nil,
         sourceCreatedAfter: Date? = nil,
         firstSeenAt: Date = Date(),
         lastCapturedAt: Date? = nil) {
        self.id = id
        self.nickname = nickname
        self.email = email
        self.planType = planType
        self.snapshot = usage.map(CodexCachedUsage.init)
        self.captureAfter = captureAfter
        self.sourceCreatedAfter = sourceCreatedAfter
        self.firstSeenAt = firstSeenAt
        self.lastCapturedAt = lastCapturedAt ?? usage?.snapshotAt
    }

    var usage: CodexUsage? { snapshot?.usage(email: email, fallbackPlan: planType) }
    var isPending: Bool { captureAfter != nil }

    var displayName: String {
        if let nickname = nickname?.trimmingCharacters(in: .whitespacesAndNewlines), !nickname.isEmpty {
            return nickname
        }
        if let plan = planType?.trimmingCharacters(in: .whitespacesAndNewlines), !plan.isEmpty {
            return plan.capitalized
        }
        return "Codex account"
    }

    // Tolerant decoding makes the local cache forward-compatible with the
    // earliest schema while still refusing a missing identity key.
    enum CodingKeys: String, CodingKey {
        case id, nickname, email, planType, snapshot, captureAfter, sourceCreatedAfter, firstSeenAt, lastCapturedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        nickname = try? c.decodeIfPresent(String.self, forKey: .nickname)
        email = try? c.decodeIfPresent(String.self, forKey: .email)
        planType = try? c.decodeIfPresent(String.self, forKey: .planType)
        snapshot = try? c.decodeIfPresent(CodexCachedUsage.self, forKey: .snapshot)
        captureAfter = try? c.decodeIfPresent(Date.self, forKey: .captureAfter)
        sourceCreatedAfter = try? c.decodeIfPresent(Date.self, forKey: .sourceCreatedAfter)
        firstSeenAt = (try? c.decodeIfPresent(Date.self, forKey: .firstSeenAt)) ?? .distantPast
        lastCapturedAt = try? c.decodeIfPresent(Date.self, forKey: .lastCapturedAt)
    }
}

/// The full local cache. `forgottenAfter` prevents a forgotten current account
/// from instantly reappearing from the same old rollout; a genuinely new task
/// after Forget will discover it again.
struct CodexAccountRegistry: Codable, Equatable {
    static let currentVersion = 1

    var v: Int = currentVersion
    var accounts: [CodexAccount] = []
    var activeAccountID: String?
    var activeAuthModifiedAt: Date?
    var forgottenAfter: [String: Date] = [:]

    enum CodingKeys: String, CodingKey {
        case v, accounts, activeAccountID, activeAuthModifiedAt, forgottenAfter
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = (try? c.decodeIfPresent(Int.self, forKey: .v)) ?? 1
        accounts = (try? c.decodeIfPresent([CodexAccount].self, forKey: .accounts)) ?? []
        activeAccountID = try? c.decodeIfPresent(String.self, forKey: .activeAccountID)
        activeAuthModifiedAt = try? c.decodeIfPresent(Date.self, forKey: .activeAuthModifiedAt)
        forgottenAfter = (try? c.decodeIfPresent([String: Date].self, forKey: .forgottenAfter)) ?? [:]
    }

    /// Current identity first; the rest retain discovery order so flipping
    /// between Personal and Team is predictable without inventing a workspace
    /// ordering from an email address.
    func displayAccounts() -> [CodexAccount] {
        accounts.enumerated().sorted { lhs, rhs in
            let lhsCurrent = lhs.element.id == activeAccountID
            let rhsCurrent = rhs.element.id == activeAccountID
            if lhsCurrent != rhsCurrent { return lhsCurrent }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// Merge one stable local observation. This is pure model logic so the
    /// attribution rules can be tested without a real Codex account or files.
    @discardableResult
    mutating func apply(_ observation: CodexObservation, now: Date = Date()) -> CodexRegistryChange {
        let before = self
        var capturedAccountID: String?

        guard observation.isStable, let identity = observation.identity else {
            return CodexRegistryChange(changed: false, capturedAccountID: nil)
        }

        let accountID = identity.accountKey
        var rediscoveryFence: Date?

        // A forgotten account stays absent until an unmistakably newer task
        // appears. Do this before upserting so its old cache cannot resurrect.
        if let forgottenAt = forgottenAfter[accountID] {
            guard observation.readings.contains(where: { Self.isFresh($0, after: forgottenAt) }) else {
                activeAccountID = accountID
                activeAuthModifiedAt = identity.authModifiedAt
                return CodexRegistryChange(changed: self != before, capturedAccountID: nil)
            }
            forgottenAfter[accountID] = nil
            rediscoveryFence = forgottenAt
        }

        // There is no earlier Dash identity to compare on the first v1.6 run.
        // Preserve the old singleton behavior in that narrow bootstrap case:
        // import a current-looking snapshot when auth.json predates the event.
        // Every later auth/account change gets the stronger new-task file fence.
        let isBootstrap = accounts.isEmpty && activeAccountID == nil
        let activeChanged = activeAccountID != accountID
        // Same identity with a rewritten auth file is ambiguous too: it may be
        // a token refresh, but could also represent a switch made while Dash
        // was not running. Requiring one fresh task is the safe trade-off.
        let authChanged = !activeChanged && activeAuthModifiedAt != identity.authModifiedAt
        var requiresFreshSnapshot = !isBootstrap && (activeChanged || authChanged)
        if isBootstrap,
           !observation.readings.contains(where: {
               CodexMonitor.labelAppliesToSnapshot(authModified: identity.authModifiedAt,
                                                   snapshotAt: $0.usage.snapshotAt)
           }) {
            // No snapshot can even be labelled as current, so fall back to the
            // normal post-auth new-task requirement rather than guessing.
            requiresFreshSnapshot = true
        }

        let index: Int
        if let existing = accounts.firstIndex(where: { $0.id == accountID }) {
            index = existing
        } else {
            accounts.append(CodexAccount(id: accountID,
                                         email: identity.email,
                                         planType: identity.planType,
                                         firstSeenAt: now))
            index = accounts.count - 1
            if !isBootstrap { requiresFreshSnapshot = true }
        }

        var account = accounts[index]
        if let email = identity.email, account.email != email { account.email = email }
        if let plan = identity.planType, account.planType != plan { account.planType = plan }

        if requiresFreshSnapshot {
            let fence = identity.authModifiedAt ?? now
            account.sourceCreatedAfter = max(account.sourceCreatedAfter ?? fence, fence)
            account.captureAfter = max(account.captureAfter ?? fence, fence)
        }
        if let rediscoveryFence {
            account.sourceCreatedAfter = max(account.sourceCreatedAfter ?? rediscoveryFence, rediscoveryFence)
            account.captureAfter = max(account.captureAfter ?? rediscoveryFence, rediscoveryFence)
        }

        activeAccountID = accountID
        activeAuthModifiedAt = identity.authModifiedAt

        let eligibleReadings = observation.readings.filter { candidate in
            let isNewer = account.snapshot.map { candidate.usage.snapshotAt >= $0.snapshotAt } ?? true
            let bootstrapSafe = !isBootstrap || CodexMonitor.labelAppliesToSnapshot(
                authModified: identity.authModifiedAt, snapshotAt: candidate.usage.snapshotAt)
            return Self.isSafeToAttribute(candidate, after: account.sourceCreatedAfter)
                && isNewer && bootstrapSafe
        }
        if let reading = CodexReading.newest(in: eligibleReadings) {
            let wasPending = account.captureAfter != nil
            let hadSnapshot = account.snapshot != nil
            account.snapshot = CodexCachedUsage(reading.usage)
            account.lastCapturedAt = reading.usage.snapshotAt
            account.captureAfter = nil
            if wasPending || !hadSnapshot { capturedAccountID = accountID }
        }

        accounts[index] = account
        return CodexRegistryChange(changed: self != before, capturedAccountID: capturedAccountID)
    }

    mutating func rename(accountID: String, nickname: String) -> Bool {
        guard let index = accounts.firstIndex(where: { $0.id == accountID }) else { return false }
        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? nil : trimmed
        guard accounts[index].nickname != value else { return false }
        accounts[index].nickname = value
        return true
    }

    mutating func forget(accountID: String, now: Date = Date()) -> Bool {
        let count = accounts.count
        accounts.removeAll { $0.id == accountID }
        guard accounts.count != count else { return false }
        forgottenAfter[accountID] = now
        if activeAccountID == accountID { activeAuthModifiedAt = nil }
        return true
    }

    static func isSafeToAttribute(_ reading: CodexReading, after fence: Date?) -> Bool {
        guard let fence else { return true }
        guard let sourceCreatedAt = reading.sourceCreatedAt else { return false }
        return sourceCreatedAt >= fence && reading.usage.snapshotAt >= fence
    }

    private static func isFresh(_ reading: CodexReading, after date: Date) -> Bool {
        guard let sourceCreatedAt = reading.sourceCreatedAt else { return false }
        return sourceCreatedAt >= date && reading.usage.snapshotAt >= date
    }

}

struct CodexRegistryChange: Equatable {
    var changed: Bool
    var capturedAccountID: String?
}

/// Local JSON persistence for the Codex-only cache. Files are atomic and
/// owner-readable only; corruption is quarantined before any later save can
/// replace the user's only copy.
enum CodexAccountStore {
    static var fileURL: URL { AppSupport.dir.appendingPathComponent("codex-accounts.json") }

    static func load(from url: URL? = nil) -> CodexAccountRegistry {
        let url = url ?? fileURL
        guard let data = try? Data(contentsOf: url) else { return CodexAccountRegistry() }
        if let decoded = try? JSONDecoder().decode(CodexAccountRegistry.self, from: data) {
            return decoded
        }
        let quarantine = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).corrupt-\(Int(Date().timeIntervalSince1970))")
        try? FileManager.default.moveItem(at: url, to: quarantine)
        return CodexAccountRegistry()
    }

    static func save(_ registry: CodexAccountRegistry, to url: URL? = nil) {
        let url = url ?? fileURL
        let fm = FileManager.default
        let parent = url.deletingLastPathComponent()
        try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
        // Only tighten the app's own directory; callers can pass a temp path in
        // tests and must never cause their containing directory to be chmod'd.
        if url.path == fileURL.path {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        }
        guard let data = try? JSONEncoder().encode(registry) else { return }
        try? data.write(to: url, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

// MARK: - Codex filesystem reader

enum CodexMonitor {
    /// ~/.codex, or $CODEX_HOME when set (it relocates the whole Codex home).
    static var codexHome: URL {
        if let h = ProcessInfo.processInfo.environment["CODEX_HOME"], !h.isEmpty {
            return URL(fileURLWithPath: (h as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }
    static var sessionsDir: URL { codexHome.appendingPathComponent("sessions") }
    static var archivedDir: URL { codexHome.appendingPathComponent("archived_sessions") }
    static var authFile: URL { codexHome.appendingPathComponent("auth.json") }

    /// An auth file alone is enough to show a pending card before the first
    /// local token-count event has been written.
    static func isPresent() -> Bool {
        FileManager.default.fileExists(atPath: sessionsDir.path)
            || FileManager.default.fileExists(atPath: archivedDir.path)
            || FileManager.default.fileExists(atPath: authFile.path)
    }

    /// Read the active identity before and after scanning rollout files. If
    /// auth.json changes mid-read, return an unstable observation rather than
    /// marrying a potentially old event to the new login.
    static func observe() -> CodexObservation {
        let before = accountIdentity()
        let readings = currentReadings(jwtPlan: before?.planType)
        let after = accountIdentity()
        guard before == after else {
            return CodexObservation(identity: after, reading: nil, isStable: false)
        }
        return CodexObservation(identity: before,
                                reading: readings.first,
                                isStable: true,
                                additionalReadings: Array(readings.dropFirst()))
    }

    /// Backward-compatible single-snapshot helper. The multi-account model
    /// uses `observe()` and applies stricter post-switch attribution itself.
    static func currentUsage(now: Date = Date()) -> CodexUsage? {
        let observation = observe()
        guard observation.isStable,
              let reading = CodexReading.newest(in: observation.readings) else { return nil }
        var usage = reading.usage
        if let identity = observation.identity,
           labelAppliesToSnapshot(authModified: identity.authModifiedAt, snapshotAt: usage.snapshotAt) {
            usage.accountEmail = identity.email
            if usage.planType == nil { usage.planType = identity.planType }
        }
        return usage
    }

    /// auth.json describes the currently signed-in account; trust it to label a
    /// snapshot only if it wasn't rewritten after the snapshot's turn. (A plain
    /// token refresh also bumps it — dropping a label is safer than guessing.)
    static func labelAppliesToSnapshot(authModified: Date?, snapshotAt: Date) -> Bool {
        guard let authModified else { return true }
        return authModified <= snapshotAt
    }

    // MARK: Identity and pure builders

    /// A stable local identifier with no raw account id in it. 96 digest bits
    /// leaves collision risk negligible while keeping local note keys compact.
    static func accountKey(accountID: String) -> String? {
        let trimmed = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data(trimmed.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "codex-\(hex.prefix(24))"
    }

    /// Codex writes `used_percent`, not remaining percentage. The dashboard
    /// always labels the displayed interpretation so a cached 57% cannot be
    /// mistaken for 57% left. Clamp malformed values defensively for display;
    /// the raw metric still drives the usage bar and cap state.
    static func percentLabel(usedPercent: Double, showRemaining: Bool) -> String {
        let used = min(100, max(0, usedPercent))
        if showRemaining {
            return "\(Int((100 - used).rounded()))% left"
        }
        return "\(Int(used.rounded()))% used"
    }

    /// Non-secret identity claims from the active ChatGPT OAuth id_token. We
    /// decode the JWT payload only for local display/attribution metadata; it
    /// is never verified, logged, sent, or persisted.
    static func accountIdentity(authURL: URL? = nil) -> CodexIdentity? {
        let url = authURL ?? authFile
        guard let claims = authClaims(authURL: url),
              let auth = claims["https://api.openai.com/auth"] as? [String: Any],
              let rawID = auth["chatgpt_account_id"] as? String,
              let key = accountKey(accountID: rawID) else { return nil }
        let label = displayLabel(from: claims)
        return CodexIdentity(accountKey: key,
                             email: label.email,
                             planType: label.plan,
                             authModifiedAt: fileModified(url))
    }

    /// Non-secret display claims from `auth.json`. Kept separately from
    /// `accountIdentity` for old callers/tests whose fixture lacks an account id.
    static func accountLabel(authURL: URL? = nil) -> (email: String?, plan: String?) {
        guard let claims = authClaims(authURL: authURL ?? authFile) else { return (nil, nil) }
        return displayLabel(from: claims)
    }

    /// Decode a JWT's payload claims WITHOUT verifying the signature — used only
    /// to read display claims, never as a trust boundary.
    static func decodeJWTClaims(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2, let data = base64urlDecode(String(parts[1])) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Map a rolling-window length to Codex's human label, matching the client's
    /// `get_limits_duration` ±5% tolerance buckets. Anything else → "usage".
    static func windowLabel(minutes: Double?) -> String {
        guard let m = minutes else { return "usage" }
        func approx(_ expected: Double) -> Bool { m >= expected * 0.95 && m <= expected * 1.05 }
        if approx(300) { return "5h" }
        if approx(1440) { return "daily" }
        if approx(10080) { return "weekly" }
        if approx(43200) { return "monthly" }
        if approx(525600) { return "annual" }
        return "usage"
    }

    /// Build a `CodexUsage` from a decoded `rate_limits` object. `primary` and
    /// `secondary` are each `{used_percent, window_minutes, resets_at}`; either
    /// may be absent. Returns nil when neither window is present.
    static func usage(fromRateLimits rl: [String: Any],
                      snapshotAt: Date,
                      email: String?,
                      jwtPlan: String?) -> CodexUsage? {
        var windows: [CodexWindow] = []
        for key in ["primary", "secondary"] {
            guard let w = rl[key] as? [String: Any],
                  let pct = number(w["used_percent"]) else { continue }
            let reset: Date?
            if let at = number(w["resets_at"]) {
                reset = Date(timeIntervalSince1970: at)
            } else if let inSeconds = number(w["resets_in_seconds"]) {
                reset = snapshotAt.addingTimeInterval(inSeconds)
            } else {
                reset = nil
            }
            windows.append(CodexWindow(label: windowLabel(minutes: number(w["window_minutes"])),
                                       metric: UsageMetric(utilization: pct, resetsAt: reset)))
        }
        guard !windows.isEmpty else { return nil }
        return CodexUsage(windows: windows,
                          planType: (rl["plan_type"] as? String) ?? jwtPlan,
                          accountEmail: email,
                          snapshotAt: snapshotAt)
    }

    // MARK: File scanning

    /// Rollout files under one root (sessions/ or archived_sessions/), newest
    /// mtime first, capped — we only ever need the most recent handful.
    static func rolloutFiles(in root: URL, limit: Int = 24) -> [URL] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root,
                                     includingPropertiesForKeys: [.contentModificationDateKey],
                                     options: [.skipsHiddenFiles]) else { return [] }
        var found: [(url: URL, modified: Date)] = []
        for case let url as URL in en {
            guard url.lastPathComponent.hasPrefix("rollout-"),
                  url.pathExtension == "jsonl" else { continue }
            found.append((url, fileModified(url) ?? .distantPast))
        }
        return found.sorted { $0.modified > $1.modified }.prefix(limit).map(\.url)
    }

    /// The freshest `rate_limits` snapshot: walk files newest-first and return
    /// the last token_count line of the first file that has one. Newest-written
    /// FILE wins, not a cross-session timestamp sort — concurrent sessions can
    /// lag independently and invert a global timestamp ordering.
    static func latestTokenCount(in files: [URL]) -> (rl: [String: Any], at: Date)? {
        guard let result = latestTokenCountWithSource(in: files) else { return nil }
        return (result.rl, result.at)
    }

    private static func latestTokenCountWithSource(in files: [URL]) -> (rl: [String: Any], at: Date, source: URL)? {
        tokenCountsWithSource(in: files).first
    }

    /// One latest token-count event per rollout file, preserving the caller's
    /// newest-mtime-first order. This lets the identity layer ignore a late old
    /// task while still finding a safe new task behind it.
    private static func tokenCountsWithSource(in files: [URL]) -> [(rl: [String: Any], at: Date, source: URL)] {
        files.compactMap { url in
            guard let text = tail(of: url) else { return nil }
            for line in text.components(separatedBy: "\n").reversed() where !line.isEmpty {
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      obj["type"] as? String == "event_msg",
                      let payload = obj["payload"] as? [String: Any],
                      payload["type"] as? String == "token_count",
                      let rl = payload["rate_limits"] as? [String: Any] else { continue }
                let at = (obj["timestamp"] as? String).flatMap(iso) ?? fileModified(url) ?? Date()
                return (rl, at, url)
            }
            return nil
        }
    }

    private static func currentReadings(jwtPlan: String?) -> [CodexReading] {
        let active = tokenCountsWithSource(in: rolloutFiles(in: sessionsDir))
        // Archives can be very large; only inspect them when no active rollout
        // has a token-count event, preserving the previous common fast path.
        let rawReadings = active.isEmpty
            ? tokenCountsWithSource(in: rolloutFiles(in: archivedDir))
            : active
        return rawReadings.compactMap { raw in
            guard let usage = usage(fromRateLimits: raw.rl,
                                    snapshotAt: raw.at,
                                    email: nil,
                                    jwtPlan: jwtPlan) else { return nil }
            return CodexReading(usage: usage,
                                sourceCreatedAt: fileCreated(raw.source),
                                sourceModifiedAt: fileModified(raw.source))
        }
    }

    // MARK: Small helpers

    private static func authClaims(authURL: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: authURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = obj["tokens"] as? [String: Any],
              let idToken = tokens["id_token"] as? String else { return nil }
        return decodeJWTClaims(idToken)
    }

    private static func displayLabel(from claims: [String: Any]) -> (email: String?, plan: String?) {
        let email = (claims["email"] as? String)
            ?? ((claims["https://api.openai.com/profile"] as? [String: Any])?["email"] as? String)
        let plan = (claims["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_plan_type"] as? String
        return (email, plan)
    }

    private static func fileModified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private static func fileCreated(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }

    /// The last `maxBytes` of a file as UTF-8 text (whole file if smaller),
    /// trimmed to a clean line boundary. A token_count event is appended per
    /// turn, so the newest one is near the end even in a large transcript.
    private static func tail(of url: URL, maxBytes: UInt64 = 262_144) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > maxBytes ? end - maxBytes : 0
        do { try handle.seek(toOffset: start) } catch { return nil }
        guard var data = try? handle.readToEnd() else { return nil }
        if start > 0, let newline = data.firstIndex(of: 0x0A) {
            data = data.subdata(in: data.index(after: newline)..<data.endIndex)
        }
        return String(data: data, encoding: .utf8)
    }

    private static func base64urlDecode(_ s: String) -> Data? {
        var str = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while str.count % 4 != 0 { str += "=" }
        return Data(base64Encoded: str)
    }

    private static func number(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static func iso(_ s: String) -> Date? { isoFrac.date(from: s) ?? isoPlain.date(from: s) }
}
