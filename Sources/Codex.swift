import Foundation

/// Local Codex usage awareness — pure file reading, nothing leaves the machine.
///
/// The OpenAI Codex app (`com.openai.codex`) and the `codex` CLI share one
/// rollout format: every turn appends a `token_count` event carrying the
/// `rate_limits` snapshot the backend returned (used %, window length, reset
/// time, plan). We surface the newest snapshot as an at-a-glance usage card,
/// mirroring the per-account Claude gauges — no keys, no network, no polling
/// of OpenAI. The card appears only when a Codex install with usable data is
/// present (and the pref is on).
///
/// Honesty note: this is a per-request cached value written only when Codex
/// runs a turn, so it's "last known" between sessions — the card shows its age.
/// It can also lag the true counter when several sessions run at once, so we
/// read the most-recently-written session file rather than sorting embedded
/// timestamps across concurrent sessions.

/// One Codex usage window (the 5-hour, weekly, or monthly limit, per plan).
struct CodexWindow: Equatable {
    var label: String        // "5h", "weekly", "monthly", … (see windowLabel)
    var metric: UsageMetric  // utilization % + reset time — reuses the Claude type
}

/// A snapshot of the logged-in Codex account's usage, read from local files.
/// Fields are all stable across reads (no wall-clock in here) so an unchanged
/// snapshot compares equal and doesn't republish every poll — freshness/staleness
/// is derived live in the view from `snapshotAt`.
struct CodexUsage: Equatable {
    var windows: [CodexWindow]    // primary + secondary, whichever the plan exposes
    var planType: String?         // "team", "plus", … (from the snapshot, else the JWT)
    var accountEmail: String?     // display label only (from the auth.json id_token JWT)
    var snapshotAt: Date          // when Codex recorded this snapshot (its last turn)
}

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

    /// A Codex install with session data is present (gates the whole feature).
    static func isPresent() -> Bool {
        FileManager.default.fileExists(atPath: sessionsDir.path)
            || FileManager.default.fileExists(atPath: archivedDir.path)
    }

    /// Current usage, or nil when there's no Codex snapshot to show.
    ///
    /// Safe to call OFF the main actor (only touches the filesystem + Foundation);
    /// `AppModel.refreshCodex` runs it detached so a big session file never blocks
    /// the UI. Active sessions live in `sessions/`; the (larger, never-pruned)
    /// archive is scanned only if nothing current is there, so the common path
    /// never crawls the whole archive.
    static func currentUsage(now: Date = Date()) -> CodexUsage? {
        guard let (rl, at) = latestTokenCount(in: rolloutFiles(in: sessionsDir))
                ?? latestTokenCount(in: rolloutFiles(in: archivedDir)) else { return nil }
        // The email/plan label comes from auth.json (the CURRENT login). Only
        // trust it to describe THESE numbers if the login wasn't switched after
        // the snapshot's turn — otherwise show the gauges without a false identity.
        let label = labelAppliesToSnapshot(authModified: fileModified(authFile), snapshotAt: at)
            ? accountLabel() : (email: nil, plan: nil)
        return usage(fromRateLimits: rl, snapshotAt: at, email: label.email, jwtPlan: label.plan)
    }

    /// auth.json describes the currently signed-in account; trust it to label a
    /// snapshot only if it wasn't rewritten (account switch) after the snapshot
    /// was recorded. (A plain token refresh also bumps it — this errs toward
    /// dropping the email over misattributing it, which is the safe direction.)
    static func labelAppliesToSnapshot(authModified: Date?, snapshotAt: Date) -> Bool {
        guard let authModified else { return true }
        return authModified <= snapshotAt
    }

    // MARK: Pure builders (unit-tested without the filesystem)

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
                reset = snapshotAt.addingTimeInterval(inSeconds)   // relative fallback
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

    /// Non-secret display claims from the ChatGPT OAuth `id_token` in auth.json.
    /// We decode ONLY the JWT payload's public claims (email, plan) for a label —
    /// the raw token strings are credentials and are never read out or logged.
    static func accountLabel(authURL: URL? = nil) -> (email: String?, plan: String?) {
        let url = authURL ?? authFile
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = obj["tokens"] as? [String: Any],
              let idToken = tokens["id_token"] as? String,
              let claims = decodeJWTClaims(idToken) else { return (nil, nil) }
        let email = (claims["email"] as? String)
            ?? ((claims["https://api.openai.com/profile"] as? [String: Any])?["email"] as? String)
        let plan = (claims["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_plan_type"] as? String
        return (email, plan)
    }

    /// Decode a JWT's payload claims WITHOUT verifying the signature — used only
    /// to read display claims, never as a trust boundary.
    static func decodeJWTClaims(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2, let data = base64urlDecode(String(parts[1])) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: File scanning

    /// Rollout files under one root (sessions/ or archived_sessions/), newest
    /// mtime first, capped — we only ever need the most recent handful. mtimes
    /// are prefetched by the enumerator, so this is a directory walk, not a
    /// stat-per-file storm.
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
    /// the last `token_count` line of the first file that has one, plus the time
    /// Codex stamped it. (Newest-written file, not a cross-session timestamp sort
    /// — concurrent sessions lag independently and would invert such a sort.)
    /// Reads only each file's tail, so a multi-MB session transcript is cheap.
    static func latestTokenCount(in files: [URL]) -> (rl: [String: Any], at: Date)? {
        for url in files {
            guard let text = tail(of: url) else { continue }
            for line in text.components(separatedBy: "\n").reversed() where !line.isEmpty {
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      obj["type"] as? String == "event_msg",
                      let payload = obj["payload"] as? [String: Any],
                      payload["type"] as? String == "token_count",
                      let rl = payload["rate_limits"] as? [String: Any] else { continue }
                let at = (obj["timestamp"] as? String).flatMap(iso) ?? fileModified(url) ?? Date()
                return (rl, at)
            }
        }
        return nil
    }

    // MARK: Small helpers

    private static func fileModified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// The last `maxBytes` of a file as UTF-8 text (whole file if smaller),
    /// trimmed to a clean line boundary. `token_count` events are appended per
    /// turn, so the newest one is always near the end — no need to read a
    /// multi-megabyte transcript into memory just to parse its tail.
    private static func tail(of url: URL, maxBytes: UInt64 = 262_144) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > maxBytes ? end - maxBytes : 0
        do { try handle.seek(toOffset: start) } catch { return nil }
        guard var data = try? handle.readToEnd() else { return nil }
        // Drop the partial first line so we begin on a boundary (also guarantees
        // valid UTF-8 at the front — the split point may bisect a character).
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
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    private static func iso(_ s: String) -> Date? { isoFrac.date(from: s) ?? isoPlain.date(from: s) }
}
