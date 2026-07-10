import Foundation
import AppKit
import Combine
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var usage: [String: UsageState] = [:]   // by account id
    @Published private(set) var lastRefresh: Date?
    /// A conservative, cross-account warning. It only appears when every
    /// configured account fails in the same refresh cycle for a reason that
    /// could plausibly be an upstream Claude/service problem.
    @Published private(set) var globalUsageProblem: UsageProblem?
    /// Bumped once a minute so reset countdowns stay live between polls.
    @Published private(set) var displayTick = 0
    /// Board layer: notes and Claude Code sessions.
    @Published private(set) var notes: NotesData = NotesStore.load()
    @Published private(set) var ccSessions: [CCSession] = []
    /// Board account that owns the current Claude Code login (matched by the
    /// CLI's organizationUuid). Sessions render on that account's card; the
    /// standalone section only appears when no account matches.
    @Published private(set) var ccOwnerAccountId: String?
    /// Remembered local Codex accounts. Their cache is identity-keyed and
    /// contains only last-known rate-limit snapshots — never Codex tokens.
    @Published private(set) var codexAccounts: [CodexAccount] = []
    /// Hash-derived id of the locally active Codex account, if readable.
    @Published private(set) var codexCurrentAccountID: String?
    /// True while a user-initiated refresh is in flight (drives the spinner).
    @Published private(set) var isRefreshing = false

    private let defaultsKey = "accounts_v1"
    private var pollTimer: Timer?
    private var tickTimer: Timer?
    private var notifiedThreshold: Set<String> = []
    private var cappedAwaitingReset: Set<String> = []
    // Bumped when an account's key changes or it's removed, so an in-flight
    // fetch started under the old key/config can't overwrite fresh state.
    private var fetchEpoch: [String: Int] = [:]
    /// Prevent a timer, wake event, and a manual refresh from racing the same
    /// account. The epoch is part of the key so replacing a credential can
    /// immediately fetch with the new key while an old request winds down.
    private var inFlightFetchEpochs: [String: Set<Int>] = [:]
    private var failureCounts: [String: Int] = [:]
    private var authenticationFailureCounts: [String: Int] = [:]
    private var retryNotBefore: [String: Date] = [:]
    // Last (utilization, time) sample per account, for burn-rate projection.
    private var lastSample: [String: (util: Double, at: Date)] = [:]
    private var notesSaveTask: Task<Void, Never>?
    private var codexRegistry = CodexAccountRegistry()
    private var codexRefreshEpoch = 0
    private var codexRefreshInFlight = false

    init() {
        load()
        for a in accounts { usage[a.id] = .unknown }
        codexRegistry = CodexAccountStore.load()
        publishCodexAccounts()
    }

    /// Accounts in the user's preferred order (flagged accounts always first).
    /// Sorting keys off last-known session usage; unknown states sort last in
    /// the usage-based modes.
    var sortedAccounts: [Account] {
        let base: [Account]
        switch Prefs.sortMode {
        case .manual:
            base = accounts
        case .headroom:
            base = accounts.sorted { sessionPct($0) ?? 101 < sessionPct($1) ?? 101 }
        case .used:
            base = accounts.sorted { sessionPct($0) ?? -1 > sessionPct($1) ?? -1 }
        }
        return base.sorted { isFlagged($0.id) && !isFlagged($1.id) }   // stable sort
    }

    func isFlagged(_ id: String) -> Bool { notes.accounts[id]?.flagged == true }

    /// Anything anywhere that needs the user: manual flag, dead key, or a
    /// Claude Code session waiting for input.
    var anyAttention: Bool {
        accounts.contains { isFlagged($0.id) || (usage[$0.id]?.usageProblem?.needsSignIn ?? false) }
            || ccSessions.contains(where: \.waiting)
    }

    // MARK: Notes

    func setNote(accountId: String, text: String) {
        var n = notes.accounts[accountId] ?? AccountNote()
        n.text = text
        n.updatedAt = Date()
        notes.accounts[accountId] = n
        scheduleNotesSave()
    }

    func setGlobalNote(_ text: String) {
        notes.global = text
        scheduleNotesSave()
    }

    func toggleFlag(accountId: String) {
        var n = notes.accounts[accountId] ?? AccountNote()
        n.flagged.toggle()
        notes.accounts[accountId] = n
        scheduleNotesSave()
    }

    private func scheduleNotesSave() {
        notesSaveTask?.cancel()
        let snapshot = notes
        notesSaveTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            NotesStore.save(snapshot)
        }
    }

    /// Synchronous save — called on edit-end, app termination, and SIGTERM so
    /// the debounce window can never eat typed notes.
    func flushNotesNow() {
        notesSaveTask?.cancel()
        NotesStore.save(notes)
    }

    private func sessionPct(_ a: Account) -> Double? {
        usage[a.id]?.snapshot?.session?.utilization
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
            Task { _ = await refresh(acct) }
        } else {
            usage[id] = .problem(.keychainUnavailable)
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
                usage[id] = .problem(.keychainUnavailable)
                return
            }
            // Failure evidence belongs to one credential epoch. A replacement
            // key must earn its own two auth confirmations and must not inherit
            // transient backoff from the previous credential.
            authenticationFailureCounts[id] = nil
            failureCounts[id] = nil
            retryNotBefore[id] = nil
            usage[id] = .unknown
        }
        Task { _ = await refresh(accounts[idx], force: true) }
    }

    /// Swap two accounts' positions in the persisted order. Callers compute the
    /// pair from the VISIBLE order so reordering matches what the user sees
    /// (the raw array is display-transformed by flag-pinning in sortedAccounts).
    func swapAccounts(_ id1: String, _ id2: String) {
        guard let a = accounts.firstIndex(where: { $0.id == id1 }),
              let b = accounts.firstIndex(where: { $0.id == id2 }) else { return }
        accounts.swapAt(a, b)
        persist()
    }

    func removeAccount(_ account: Account) {
        fetchEpoch[account.id, default: 0] += 1   // in-flight fetches must not resurrect it
        Keychain.delete(account: account.id)
        accounts.removeAll { $0.id == account.id }
        usage[account.id] = nil
        notifiedThreshold.remove(account.id)
        cappedAwaitingReset.remove(account.id)
        lastSample[account.id] = nil
        inFlightFetchEpochs[account.id] = nil
        failureCounts[account.id] = nil
        authenticationFailureCounts[account.id] = nil
        retryNotBefore[account.id] = nil
        notes.accounts[account.id] = nil
        if accounts.count < 2 { globalUsageProblem = nil }
        scheduleNotesSave()
        persist()
    }

    // MARK: Fetching

    enum FetchOutcome {
        case success(String)
        case problem(String, UsageProblem)
        case skipped
    }

    func refreshAll(force: Bool = false) async {
        let refreshAccounts = accounts
        let outcomes = await withTaskGroup(of: FetchOutcome.self, returning: [FetchOutcome].self) { group in
            for account in refreshAccounts {
                group.addTask { await self.refresh(account, force: force) }
            }
            var results: [FetchOutcome] = []
            for await outcome in group { results.append(outcome) }
            return results
        }
        updateGlobalUsageProblem(outcomes, expectedAccountCount: refreshAccounts.count)
        // lastRefresh advances inside each successful fetch — a total outage
        // must not keep stamping the footer with fresh-looking times.
    }

    /// Fetch one account, retaining its last known usage when a request fails.
    /// A credential is only labelled as needing sign-in after a second,
    /// independent explicit invalid-authorization response.
    @discardableResult
    func refresh(_ account: Account, force: Bool = false) async -> FetchOutcome {
        let accountId = account.id
        let now = Date()
        let epoch = fetchEpoch[accountId, default: 0]
        if !force, let retryAt = retryNotBefore[accountId], retryAt > now { return .skipped }
        // Respect a server-requested delay even for the Refresh button.
        if force, case .rateLimited(let retryAt?) = usage[accountId]?.usageProblem, retryAt > now {
            return .skipped
        }
        guard !(inFlightFetchEpochs[accountId]?.contains(epoch) ?? false) else { return .skipped }
        inFlightFetchEpochs[accountId, default: []].insert(epoch)
        defer {
            var epochs = inFlightFetchEpochs[accountId] ?? []
            epochs.remove(epoch)
            inFlightFetchEpochs[accountId] = epochs.isEmpty ? nil : epochs
        }

        let credential = await Task.detached(operation: { Keychain.read(account: accountId) }).value
        guard fetchEpoch[accountId, default: 0] == epoch,
              accounts.contains(where: { $0.id == accountId }) else { return .skipped }
        switch credential {
        case .missing:
            let problem = UsageProblem.credentialUnavailable
            apply(problem: problem, accountId: accountId, previous: usage[accountId] ?? .unknown)
            return .problem(accountId, problem)
        case .unavailable:
            let problem = UsageProblem.keychainUnavailable
            apply(problem: problem, accountId: accountId, previous: usage[accountId] ?? .unknown)
            return .problem(accountId, problem)
        case .value(let key):
            return await refresh(account, sessionKey: key, epoch: epoch)
        }
    }

    private func refresh(_ account: Account, sessionKey key: String, epoch: Int) async -> FetchOutcome {
        let accountId = account.id
        // Silent background refresh: keep showing known-good data during the
        // round-trip instead of collapsing every row to a spinner each poll.
        let previous = usage[accountId]
        if previous?.snapshot == nil, previous?.usageProblem == nil { usage[accountId] = .loading }
        do {
            var u = try await UsageAPI.usage(sessionKey: key, orgUuid: account.orgUuid)
            guard fetchEpoch[accountId, default: 0] == epoch,
                  accounts.contains(where: { $0.id == accountId }) else { return .skipped }
            u.projectedCap = projectCap(accountId: accountId, usage: u)
            usage[accountId] = .ok(u)
            failureCounts[accountId] = nil
            authenticationFailureCounts[accountId] = nil
            retryNotBefore[accountId] = nil
            lastRefresh = Date()
            maybeNotify(account, u)
            return .success(accountId)
        } catch {
            guard fetchEpoch[accountId, default: 0] == epoch,
                  accounts.contains(where: { $0.id == accountId }) else { return .skipped }
            let received = (error as? UsageError)?.problem ?? .network(.other)
            let problem = confirmedProblem(received, accountId: accountId)
            apply(problem: problem, accountId: accountId, previous: previous ?? .unknown)
            scheduleRetry(problem, accountId: accountId)
            return .problem(accountId, problem)
        }
    }

    private func confirmedProblem(_ problem: UsageProblem, accountId: String) -> UsageProblem {
        guard problem == .signInRequired else {
            authenticationFailureCounts[accountId] = nil
            return problem
        }
        let failures = authenticationFailureCounts[accountId, default: 0] + 1
        authenticationFailureCounts[accountId] = failures
        return failures >= 2 ? .signInRequired : .signInCheck
    }

    private func apply(problem: UsageProblem, accountId: String, previous: UsageState) {
        if let snapshot = previous.snapshot {
            usage[accountId] = .stale(snapshot, problem)
        } else {
            usage[accountId] = .problem(problem)
        }
    }

    private func scheduleRetry(_ problem: UsageProblem, accountId: String) {
        guard problem.isTransient else {
            retryNotBefore[accountId] = nil
            failureCounts[accountId] = nil
            return
        }
        let now = Date()
        if case .rateLimited(let retryAt?) = problem {
            retryNotBefore[accountId] = retryAt
            return
        }
        let count = min(failureCounts[accountId, default: 0] + 1, 5)
        failureCounts[accountId] = count
        let delay = min(30.0 * pow(2, Double(count - 1)), 15 * 60)
        retryNotBefore[accountId] = now.addingTimeInterval(delay)
    }

    private func updateGlobalUsageProblem(_ outcomes: [FetchOutcome], expectedAccountCount: Int) {
        guard expectedAccountCount >= 2 else {
            globalUsageProblem = nil
            return
        }
        guard outcomes.count == expectedAccountCount,
              !outcomes.contains(where: { if case .success = $0 { return true }; return false }),
              !outcomes.contains(where: { if case .skipped = $0 { return true }; return false }) else {
            if outcomes.contains(where: { if case .success = $0 { return true }; return false }) {
                globalUsageProblem = nil
            }
            return
        }
        let problems = outcomes.compactMap { outcome -> (String, UsageProblem)? in
            if case .problem(let id, let problem) = outcome { return (id, problem) }
            return nil
        }
        guard problems.count == expectedAccountCount,
              problems.allSatisfy({ isPlausiblyServiceWide($0.1) }) else {
            globalUsageProblem = nil
            return
        }
        globalUsageProblem = .temporary(status: nil)
        // A simultaneous inconclusive auth response is not evidence that every
        // stored key died. Keep the snapshot, but phrase it as an outage until
        // a later independent confirmation is available.
        for (id, problem) in problems where problem == .signInCheck || problem == .accessDenied {
            replaceProblem(for: id, with: .temporary(status: nil))
        }
    }

    private func isPlausiblyServiceWide(_ problem: UsageProblem) -> Bool {
        switch problem {
        case .signInCheck, .accessDenied, .rateLimited, .temporary, .network: return true
        case .credentialUnavailable, .keychainUnavailable, .signInRequired,
             .responseChanged, .noOrganizations: return false
        }
    }

    private func replaceProblem(for accountId: String, with replacement: UsageProblem) {
        guard let state = usage[accountId] else { return }
        if let snapshot = state.snapshot { usage[accountId] = .stale(snapshot, replacement) }
        else { usage[accountId] = .problem(replacement) }
    }

    /// User-initiated refresh: re-fetch everything visible. Guards against
    /// stacking concurrent refreshes and drives the header spinner.
    func userRefresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        await refreshAll(force: true)
        refreshClaudeCode()
        refreshCodex()
        isRefreshing = false
    }

    /// Rebuild Claude Code sessions from hook events. Strictly hooks-only:
    /// without the opt-in install, stray events (e.g. from a test run) must
    /// never surface anything.
    func refreshClaudeCode() {
        guard ClaudeCodeMonitor.hooksInstalled() else {
            if !ccSessions.isEmpty { ccSessions = [] }
            if ccOwnerAccountId != nil { ccOwnerAccountId = nil }
            return
        }
        let sessions = ClaudeCodeMonitor.sessionsFromEvents()
        if sessions != ccSessions { ccSessions = sessions }
        let owner = matchCCOwner(loginOrgUuid: ClaudeCodeMonitor.currentLoginOrgUuid(),
                                 accounts: accounts)
        if owner != ccOwnerAccountId { ccOwnerAccountId = owner }
    }

    /// Merge the locally active Codex identity and newest rollout snapshot.
    /// Codex does not write an account id into historical rollout lines, so the
    /// registry only accepts a post-switch *new task* snapshot. This prevents a
    /// late event from an old session being painted as the newly signed-in plan.
    func refreshCodex() {
        guard Prefs.monitorCodex, CodexMonitor.isPresent() else {
            codexRefreshEpoch &+= 1
            codexRefreshInFlight = false
            if !codexAccounts.isEmpty || codexCurrentAccountID != nil {
                codexAccounts = []
                codexCurrentAccountID = nil
            }
            return
        }
        guard !codexRefreshInFlight else { return }
        codexRefreshInFlight = true
        let epoch = codexRefreshEpoch
        Task {
            let observation = await Task.detached { CodexMonitor.observe() }.value
            guard epoch == self.codexRefreshEpoch else { return }
            self.codexRefreshInFlight = false
            let change = self.codexRegistry.apply(observation)
            if change.changed {
                CodexAccountStore.save(self.codexRegistry)
                if let captured = change.capturedAccountID,
                   self.notes.migrateLegacyCodexNote(to: captured) {
                    self.scheduleNotesSave()
                }
                self.publishCodexAccounts()
            }
        }
    }

    /// Set or clear a local display nickname. This cannot affect Codex itself;
    /// it only makes Personal/Team cards recognizable when they share an email.
    func setCodexNickname(accountID: String, nickname: String) {
        guard codexRegistry.rename(accountID: accountID, nickname: nickname) else { return }
        CodexAccountStore.save(codexRegistry)
        publishCodexAccounts()
    }

    /// Forget only Claude Dash's local cache and note. A current account does
    /// not immediately reappear from old JSONL history; a new Codex task will
    /// deliberately discover it again if the user continues using that account.
    func forgetCodexAccount(accountID: String) {
        guard codexRegistry.forget(accountID: accountID) else { return }
        notes.accounts[NotesData.codexKey(for: accountID)] = nil
        scheduleNotesSave()
        CodexAccountStore.save(codexRegistry)
        publishCodexAccounts()
    }

    private func publishCodexAccounts() {
        codexAccounts = codexRegistry.displayAccounts()
        codexCurrentAccountID = codexRegistry.activeAccountID
    }

    /// Sessions for a specific account card (only the CC owner gets them).
    func ccSessions(for accountId: String) -> [CCSession] {
        ccOwnerAccountId == accountId ? ccSessions : []
    }

    /// Sessions with no owning account — rendered in the standalone section.
    var ccUnmatchedSessions: [CCSession] {
        ccOwnerAccountId == nil ? ccSessions : []
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
            Task { @MainActor in
                self.displayTick &+= 1
                self.refreshClaudeCode()
                self.refreshCodex()
            }
        }
        refreshClaudeCode()
        refreshCodex()
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
