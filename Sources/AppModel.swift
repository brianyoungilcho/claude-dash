import Foundation
import AppKit
import Combine
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var usage: [String: UsageState] = [:]   // by account id
    @Published private(set) var lastRefresh: Date?
    /// Bumped once a minute so reset countdowns stay live between polls.
    @Published private(set) var displayTick = 0

    private let defaultsKey = "accounts_v1"
    private var pollTimer: Timer?
    private var tickTimer: Timer?
    private var notifiedThreshold: Set<String> = []
    private var cappedAwaitingReset: Set<String> = []
    // Bumped when an account's key changes or it's removed, so an in-flight
    // fetch started under the old key/config can't overwrite fresh state.
    private var fetchEpoch: [String: Int] = [:]
    // Last (utilization, time) sample per account, for burn-rate projection.
    private var lastSample: [String: (util: Double, at: Date)] = [:]

    init() {
        load()
        for a in accounts { usage[a.id] = .unknown }
    }

    /// Accounts in the user's preferred order. Sorting keys off last-known
    /// session usage; unknown states sort last in the usage-based modes.
    var sortedAccounts: [Account] {
        switch Prefs.sortMode {
        case .manual:
            return accounts
        case .headroom:
            return accounts.sorted { sessionPct($0) ?? 101 < sessionPct($1) ?? 101 }
        case .used:
            return accounts.sorted { sessionPct($0) ?? -1 > sessionPct($1) ?? -1 }
        }
    }

    private func sessionPct(_ a: Account) -> Double? {
        if case .ok(let u) = usage[a.id] { return u.session?.utilization }
        return nil
    }

    // MARK: Persistence (config only; keys are in the Keychain)

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([Account].self, from: data) else { return }
        accounts = decoded
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    // MARK: Mutations

    func addAccount(sessionKey: String, org: Org, profile: ChromeProfile, displayName: String) {
        let id = UUID().uuidString
        let stored = Keychain.set(sessionKey, account: id)
        let acct = Account(
            id: id,
            displayName: displayName.isEmpty ? org.name : displayName,
            orgUuid: org.uuid,
            orgName: org.name,
            chromeProfileDir: profile.dir,
            chromeProfileLabel: profile.label
        )
        accounts.append(acct)
        persist()
        if stored {
            usage[id] = .unknown
            Task { await refresh(acct) }
        } else {
            usage[id] = .error("Couldn't save the key to the Keychain — try Edit → replace key")
        }
    }

    /// Update display name / browser profile, and optionally replace the key.
    func updateAccount(id: String, displayName: String, profile: ChromeProfile?, newSessionKey: String?) {
        guard let idx = accounts.firstIndex(where: { $0.id == id }) else { return }
        if !displayName.isEmpty { accounts[idx].displayName = displayName }
        if let p = profile {
            accounts[idx].chromeProfileDir = p.dir
            accounts[idx].chromeProfileLabel = p.label
        }
        persist()
        if let key = newSessionKey, !key.isEmpty {
            fetchEpoch[id, default: 0] += 1   // invalidate in-flight fetches with the old key
            notifiedThreshold.remove(id)
            guard Keychain.set(key, account: id) else {
                usage[id] = .error("Couldn't save the key to the Keychain — try again")
                return
            }
            usage[id] = .unknown
        }
        Task { await refresh(accounts[idx]) }
    }

    func removeAccount(_ account: Account) {
        fetchEpoch[account.id, default: 0] += 1   // in-flight fetches must not resurrect it
        Keychain.delete(account: account.id)
        accounts.removeAll { $0.id == account.id }
        usage[account.id] = nil
        notifiedThreshold.remove(account.id)
        cappedAwaitingReset.remove(account.id)
        lastSample[account.id] = nil
        persist()
    }

    // MARK: Fetching

    func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for a in accounts { group.addTask { await self.refresh(a) } }
        }
        // lastRefresh advances inside each successful fetch — a total outage
        // must not keep stamping the footer with fresh-looking times.
    }

    func refresh(_ account: Account) async {
        let accountId = account.id
        let epoch = fetchEpoch[accountId, default: 0]
        guard let key = await Task.detached(operation: { Keychain.get(account: accountId) }).value else {
            usage[accountId] = .unauthorized; return
        }
        // Silent background refresh: keep showing known-good data during the
        // round-trip instead of collapsing every row to a spinner each poll.
        let previous = usage[accountId]
        if case .ok = previous {} else { usage[accountId] = .loading }
        do {
            var u = try await UsageAPI.usage(sessionKey: key, orgUuid: account.orgUuid)
            guard fetchEpoch[accountId, default: 0] == epoch,
                  accounts.contains(where: { $0.id == accountId }) else { return }
            u.projectedCap = projectCap(accountId: accountId, usage: u)
            usage[accountId] = .ok(u)
            lastRefresh = Date()
            maybeNotify(account, u)
        } catch {
            guard fetchEpoch[accountId, default: 0] == epoch,
                  accounts.contains(where: { $0.id == accountId }) else { return }
            let e = error as? UsageError
            if e == .unauthorized {
                usage[accountId] = .unauthorized   // key death always surfaces
            } else if case .ok = previous {
                // Transient failure (network blip, 429, 5xx): keep the last
                // good snapshot rather than replacing data with an error row.
            } else {
                switch e {
                case .rateLimited: usage[accountId] = .rateLimited
                case .some(let ue): usage[accountId] = .error(ue.display)
                case .none: usage[accountId] = .error(error.localizedDescription)
                }
            }
        }
    }

    /// Burn-rate projection: at the current pace, when does session usage hit
    /// 100%? Rate is measured against an ANCHOR sample that only slides forward
    /// once it's ≥5 minutes old — so panel-open/manual refreshes seconds apart
    /// can't produce absurd rates, and slow burns accumulate over a real window
    /// instead of vanishing under a per-poll deadband. Only returns a date when
    /// the projected cap lands before the reset (otherwise the reset saves you).
    private func projectCap(accountId: String, usage u: AccountUsage) -> Date? {
        guard let util = u.session?.utilization else { return nil }
        guard let anchor = lastSample[accountId], util >= anchor.util else {
            // First sample, or usage went DOWN (session reset) — re-anchor.
            lastSample[accountId] = (util, u.fetchedAt)
            return nil
        }
        let dt = u.fetchedAt.timeIntervalSince(anchor.at)
        if dt >= 300 { lastSample[accountId] = (util, u.fetchedAt) }   // slide the window
        let dUtil = util - anchor.util
        // Need a real measurement window and real movement before projecting.
        guard dt >= 180, dUtil > 0.5, util < 100 else { return nil }
        let projected = u.fetchedAt.addingTimeInterval((100 - util) / (dUtil / dt))
        guard let reset = u.session?.resetsAt, projected < reset else { return nil }
        return projected
    }

    // MARK: Notifications

    private func maybeNotify(_ account: Account, _ u: AccountUsage) {
        let pct = u.session?.utilization ?? 0
        let threshold = Prefs.notifyThreshold

        if threshold > 0, pct >= Double(threshold), !notifiedThreshold.contains(account.id) {
            notifiedThreshold.insert(account.id)
            cappedAwaitingReset.insert(account.id)
            Notifier.post(title: "\(account.displayName) at \(Int(pct))%",
                          body: "5-hour session limit almost reached.")
        }
        if pct < Double(max(threshold - 10, 10)) {
            notifiedThreshold.remove(account.id)   // re-arm after the window resets
        }
        // A real session reset lands near 0 — raising the threshold preference
        // must not masquerade as one.
        if pct < 15, cappedAwaitingReset.remove(account.id) != nil, Prefs.notifyOnReset {
            Notifier.post(title: "\(account.displayName) session reset",
                          body: "Usage is back to \(Int(pct))% — good to go.")
        }
    }

    // MARK: Polling

    func startPolling() {
        pollTimer?.invalidate()
        Task { await refreshAll() }
        pollTimer = Timer.scheduledTimer(withTimeInterval: Prefs.pollInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.refreshAll() }
        }
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.displayTick &+= 1 }
        }
    }

    /// Re-arm the poll timer after a preferences change.
    func applyPrefsChange() { startPolling() }

    // MARK: Open in the browser

    func openChrome(_ account: Account, path: String) {
        let url = "https://claude.ai\(path)"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-na", BrowserDetect.current().appName, "--args",
                       "--profile-directory=\(account.chromeProfileDir)", url]
        try? p.run()
    }
}

/// UNUserNotificationCenter wrapper (NSUserNotification is long deprecated).
enum Notifier {
    private static var authRequested = false

    static func post(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        let fire = {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString,
                                             content: content, trigger: nil))
        }
        if authRequested { fire(); return }
        authRequested = true
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if granted { fire() }
        }
    }
}
