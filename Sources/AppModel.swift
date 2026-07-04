import Foundation
import AppKit
import Combine

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var usage: [String: UsageState] = [:]   // by account id
    @Published private(set) var lastRefresh: Date?

    private let defaultsKey = "accounts_v1"
    private var pollTimer: Timer?
    private var notifiedAt90: Set<String> = []
    // Bumped when an account's key changes or it's removed, so an in-flight
    // fetch started under the old key/config can't overwrite fresh state.
    private var fetchEpoch: [String: Int] = [:]

    init() {
        load()
        for a in accounts { usage[a.id] = .unknown }
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
            usage[id] = .error("Couldn't save the key to the Keychain — try Replace session key")
        }
    }

    /// Replace the session key for an existing account (the "Fix key" path).
    func updateKey(accountId: String, sessionKey: String) {
        // The account may have been removed while the Replace window was open —
        // don't write an orphaned secret nobody can ever delete.
        guard let a = accounts.first(where: { $0.id == accountId }) else { return }
        fetchEpoch[accountId, default: 0] += 1   // invalidate in-flight fetches with the old key
        let stored = Keychain.set(sessionKey, account: accountId)
        notifiedAt90.remove(accountId)
        guard stored else {
            usage[accountId] = .error("Couldn't save the key to the Keychain — try again")
            return
        }
        usage[accountId] = .unknown
        Task { await refresh(a) }
    }

    func removeAccount(_ account: Account) {
        fetchEpoch[account.id, default: 0] += 1   // in-flight fetches must not resurrect it
        Keychain.delete(account: account.id)
        accounts.removeAll { $0.id == account.id }
        usage[account.id] = nil
        notifiedAt90.remove(account.id)
        persist()
    }

    // MARK: Fetching

    func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for a in accounts { group.addTask { await self.refresh(a) } }
        }
        lastRefresh = Date()
    }

    func refresh(_ account: Account) async {
        let accountId = account.id
        let epoch = fetchEpoch[accountId, default: 0]
        guard let key = await Task.detached(operation: { Keychain.get(account: accountId) }).value else {
            // Missing key = same recovery path as an expired one: the row shows
            // the red "replace session key" button.
            usage[account.id] = .unauthorized; return
        }
        // Silent background refresh: keep showing known-good data during the
        // round-trip instead of collapsing every row to a spinner each poll.
        let previous = usage[accountId]
        if case .ok = previous {} else { usage[accountId] = .loading }
        do {
            let u = try await UsageAPI.usage(sessionKey: key, orgUuid: account.orgUuid)
            guard fetchEpoch[accountId, default: 0] == epoch,
                  accounts.contains(where: { $0.id == accountId }) else { return }
            usage[accountId] = .ok(u)
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

    private func maybeNotify(_ account: Account, _ u: AccountUsage) {
        let pct = u.session?.utilization ?? 0
        if pct >= 90, !notifiedAt90.contains(account.id) {
            notifiedAt90.insert(account.id)
            Notifier.post(title: "\(account.displayName) at \(Int(pct))%",
                          body: "5-hour session limit almost reached.")
        }
        if pct < 80 { notifiedAt90.remove(account.id) }   // re-arm after it resets
    }

    // MARK: Polling

    func startPolling(interval: TimeInterval = 60) {
        pollTimer?.invalidate()
        Task { await refreshAll() }
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.refreshAll() }
        }
    }

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

enum Notifier {
    static func post(title: String, body: String) {
        let n = NSUserNotification()
        n.title = title
        n.informativeText = body
        NSUserNotificationCenter.default.deliver(n)
    }
}
