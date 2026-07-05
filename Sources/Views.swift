import SwiftUI

// MARK: - Shared helpers

func usageColor(_ pct: Double) -> Color {
    pct >= 90 ? .red : pct >= 75 ? .orange : .green
}

func resetString(_ date: Date?) -> String {
    guard let date else { return "" }
    let secs = date.timeIntervalSinceNow
    if secs <= 0 { return "resetting…" }
    let totalMinutes = Int(secs) / 60
    let d = totalMinutes / 1440, h = (totalMinutes % 1440) / 60, m = totalMinutes % 60
    if d > 0 { return "resets in \(d)d \(h)h" }
    if h > 0 { return "resets in \(h)h \(m)m" }
    return "resets in \(m)m"
}

// MARK: - Usage bar

struct UsageBar: View {
    var pct: Double
    var height: CGFloat = 7
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(Color.primary.opacity(0.12))
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(usageColor(pct))
                    .frame(width: max(0, min(1, pct / 100)) * geo.size.width)
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("\(Int(pct)) percent used")
    }
}

/// One compact metric row: fixed-width label, small bar, percent, trailing text.
struct MetricLine: View {
    var label: String
    var metric: UsageMetric
    var trailing: String? = nil   // defaults to the reset countdown

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
                .lineLimit(1)
            UsageBar(pct: metric.utilization, height: 4)
            Text(Prefs.pctLabel(metric.utilization))
                .font(.system(size: 9, weight: .medium)).monospacedDigit()
                .foregroundStyle(usageColor(metric.utilization))
                .frame(minWidth: 30, alignment: .trailing)
            Text(trailing ?? resetString(metric.resetsAt))
                .font(.system(size: 8)).foregroundStyle(.secondary)
                .frame(width: 76, alignment: .trailing)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(Prefs.pctLabel(metric.utilization)), \(trailing ?? resetString(metric.resetsAt))")
    }
}

// MARK: - Dashboard panel

struct DashboardView: View {
    @ObservedObject var model: AppModel
    var onAdd: () -> Void
    var onEdit: (Account) -> Void
    var onPrefs: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.accounts.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.sortedAccounts) { account in
                            AccountRow(
                                account: account,
                                state: model.usage[account.id] ?? .unknown,
                                open: { model.openChrome(account, path: "/new") },
                                openUsage: { model.openChrome(account, path: "/settings/usage") },
                                edit: { onEdit(account) },
                                remove: { model.removeAccount(account) }
                            )
                            Divider()
                        }
                    }
                }
            }
            footer
        }
        .frame(width: 340)
        .frame(maxHeight: 560)
    }

    private var header: some View {
        HStack {
            Text("Claude Dash").font(.system(size: 13, weight: .semibold))
            Spacer()
            Button(action: onPrefs) { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .help("Preferences")
            Button(action: { Task { await model.refreshAll() } }) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh all")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.system(size: 30)).foregroundStyle(.secondary)
            Text("No accounts yet").font(.system(size: 13, weight: .medium))
            Text("Add a Claude account to see its usage and jump into the right browser profile.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Add account…", action: onAdd)
                .controlSize(.small)
        }
        .padding(20)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Button("Add account…", action: onAdd).buttonStyle(.borderless)
                Spacer()
                if let d = model.lastRefresh {
                    Text("Updated \(d.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
        }
    }
}

struct AccountRow: View {
    var account: Account
    var state: UsageState
    var open: () -> Void
    var openUsage: () -> Void
    var edit: () -> Void
    var remove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(account.displayName).font(.system(size: 12, weight: .semibold))
                    Spacer()
                    statusBadge
                }
                content
                Text(account.chromeProfileLabel)
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            VStack(alignment: .trailing, spacing: 5) {
                Button(action: open) {
                    Text("Open").font(.system(size: 11, weight: .medium))
                }
                .controlSize(.small)
                .help("Open claude.ai in \(account.chromeProfileLabel)")
                Menu {
                    Button("Edit…", action: edit)
                    Button("Open usage page", action: openUsage)
                    Divider()
                    Button("Remove account", role: .destructive, action: remove)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 24)
                .help("More actions")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .contextMenu {
            Button("Open claude.ai", action: open)
            Button("Open usage page", action: openUsage)
            Button("Edit…", action: edit)
            Divider()
            Button("Remove account", role: .destructive, action: remove)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Account \(account.displayName)")
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .ok(let u):
            let session = u.session?.utilization ?? 0
            VStack(alignment: .leading, spacing: 4) {
                // Session — the primary metric, full-size bar.
                HStack {
                    Text("Session").font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    Text(resetString(u.session?.resetsAt))
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                    Text(Prefs.pctLabel(session))
                        .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(usageColor(session))
                }
                UsageBar(pct: session)
                if let cap = u.projectedCap {
                    Label("At this pace, caps \(cap.formatted(date: .omitted, time: .shortened))",
                          systemImage: "speedometer")
                        .font(.system(size: 9)).foregroundStyle(.orange)
                }
                // Weekly + per-model caps (e.g. Fable) — compact aligned lines.
                if let weekly = u.weekly {
                    MetricLine(label: "Weekly", metric: weekly)
                }
                ForEach(Array(u.scoped.enumerated()), id: \.offset) { _, s in
                    MetricLine(label: s.name, metric: s.metric)
                }
                if let extra = u.extra {
                    MetricLine(label: "Extra",
                               metric: UsageMetric(utilization: extra.percent, resetsAt: nil),
                               trailing: extra.usedDisplay ?? "")
                }
            }
        case .loading, .unknown:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading…").font(.system(size: 11)).foregroundStyle(.secondary)
            }.frame(height: 20)
        case .unauthorized:
            Button(action: edit) {
                Label("Session key expired — replace", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
            }.buttonStyle(.borderless).foregroundStyle(.red)
        case .rateLimited:
            Text("Rate limited — retrying soon").font(.system(size: 11)).foregroundStyle(.orange)
        case .error(let m):
            Text(m).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
        }
    }

    @ViewBuilder private var statusBadge: some View {
        switch state {
        case .ok(let u):
            let five = u.session?.utilization ?? 0
            Circle().fill(usageColor(five)).frame(width: 7, height: 7)
        case .unauthorized:
            Circle().fill(Color.red).frame(width: 7, height: 7)
        default:
            EmptyView()
        }
    }
}

// MARK: - Menu bar gauges (rendered to an image)

struct MenuBarGaugesView: View {
    var accounts: [Account]
    var usage: [String: UsageState]
    var mode: Prefs.MenuBarMode = .all

    var body: some View {
        HStack(spacing: 7) {
            switch mode {
            case .icon:
                gaugeGlyph
            case .tightest:
                if let a = tightest { chip(a) } else { gaugeGlyph }
            case .all:
                if accounts.isEmpty {
                    gaugeGlyph
                } else {
                    ForEach(accounts) { a in chip(a) }
                }
            }
        }
        .padding(.horizontal, 2)
        .accessibilityLabel("Claude Dash usage gauges")
    }

    private var gaugeGlyph: some View {
        HStack(spacing: 3) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.system(size: 13, weight: .medium))
            if accounts.isEmpty { Text("Dash").font(.system(size: 11, weight: .semibold)) }
        }
    }

    private var tightest: Account? {
        accounts.max { pct($0) ?? -1 < pct($1) ?? -1 }
    }

    private func pct(_ a: Account) -> Double? {
        if case .ok(let u) = usage[a.id] { return u.session?.utilization }
        return nil
    }

    @ViewBuilder private func chip(_ a: Account) -> some View {
        let initials = String(a.displayName.prefix(2)).uppercased()
        let state = usage[a.id] ?? .unknown
        VStack(spacing: 1) {
            Text(initials).font(.system(size: 7, weight: .semibold)).foregroundStyle(.primary)
            switch state {
            case .ok(let u):
                let pct = u.session?.utilization ?? 0
                miniBar(pct)
            case .unauthorized:
                Rectangle().fill(Color.red).frame(width: 15, height: 3).cornerRadius(1.5)
            default:
                Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 15, height: 3).cornerRadius(1.5)
            }
        }
    }

    private func miniBar(_ pct: Double) -> some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(Color.primary.opacity(0.18)).frame(width: 15, height: 3)
            Rectangle().fill(usageColor(pct)).frame(width: max(0, min(1, pct/100)) * 15, height: 3)
        }.cornerRadius(1.5)
    }
}

// MARK: - Add account

struct AddAccountView: View {
    @ObservedObject var model: AppModel
    var onDone: () -> Void

    @State private var sessionKey = ""
    @State private var validating = false
    @State private var committing = false
    @State private var orgs: [Org] = []
    @State private var selectedOrg: Org?
    @State private var profiles: [ChromeProfile] = ChromeProfiles.all()
    @State private var selectedProfile: ChromeProfile?
    @State private var displayName = ""
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Claude account").font(.system(size: 15, weight: .semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("Session key").font(.system(size: 11, weight: .medium))
                HStack(spacing: 6) {
                    SecureField("sk-ant-sid…", text: $sessionKey)
                        .textFieldStyle(.roundedBorder)
                    Button("Sign in…") {
                        SignInWindow.present { key in
                            sessionKey = key
                            validate()
                        }
                    }
                    .help("Log in to claude.ai in a window — the key is captured automatically")
                }
                Text("Easiest: click Sign in… and log into the account. Manual: in that browser profile, open claude.ai → DevTools (⌥⌘I) → Application → Cookies → https://claude.ai → copy the sessionKey value.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let errorText {
                Text(errorText).font(.system(size: 11)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !orgs.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Organization").font(.system(size: 11, weight: .medium))
                    Picker("", selection: $selectedOrg) {
                        ForEach(orgs) { o in
                            Text(o.isChatOrg ? o.name : "\(o.name) — API org, no chat usage")
                                .tag(Optional(o))
                        }
                    }.labelsHidden()
                    if orgs.count > 1 {
                        Text("This login has \(orgs.count) organizations. Pick the one whose usage you want to track — it's verified before saving.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(BrowserDetect.current().appName) profile").font(.system(size: 11, weight: .medium))
                    Picker("", selection: $selectedProfile) {
                        Text("Choose…").tag(Optional<ChromeProfile>.none)
                        ForEach(profiles) { p in Text(p.label).tag(Optional(p)) }
                    }.labelsHidden()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Display name").font(.system(size: 11, weight: .medium))
                    TextField("Name shown in the dashboard", text: $displayName)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack {
                Button("Cancel", action: onDone)
                Spacer()
                if orgs.isEmpty {
                    Button(validating ? "Validating…" : "Validate key", action: validate)
                        .keyboardShortcut(.defaultAction)
                        .disabled(sessionKey.isEmpty || validating)
                } else {
                    Button(committing ? "Verifying usage…" : "Add account", action: commit)
                        .keyboardShortcut(.defaultAction)
                        .disabled(selectedOrg == nil || selectedProfile == nil || committing)
                }
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func validate() {
        errorText = nil
        validating = true
        let key = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                let found = try await UsageAPI.organizations(sessionKey: key)
                await MainActor.run {
                    orgs = found
                    selectedOrg = found.first(where: { $0.isChatOrg }) ?? found.first
                    if displayName.isEmpty { displayName = selectedOrg?.name ?? "" }
                    validating = false
                }
            } catch let e as UsageError {
                await MainActor.run { errorText = e.display; validating = false }
            } catch {
                await MainActor.run { errorText = error.localizedDescription; validating = false }
            }
        }
    }

    private func commit() {
        let key = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let org = selectedOrg, let profile = selectedProfile else { return }
        errorText = nil
        committing = true
        Task {
            do {
                // Pre-flight: prove the usage endpoint answers for THIS key + org
                // before saving, so a wrong-org pick fails here with the real reason.
                _ = try await UsageAPI.usage(sessionKey: key, orgUuid: org.uuid)
                await MainActor.run {
                    committing = false
                    model.addAccount(sessionKey: key, org: org, profile: profile, displayName: displayName)
                    onDone()
                }
            } catch let e as UsageError {
                await MainActor.run {
                    committing = false
                    errorText = "Usage check failed for “\(org.name)”: \(e.display)." +
                        (orgs.count > 1 ? " Try a different organization from the list." : "")
                }
            } catch {
                await MainActor.run { committing = false; errorText = error.localizedDescription }
            }
        }
    }
}

// MARK: - Edit account

struct EditAccountView: View {
    @ObservedObject var model: AppModel
    var account: Account
    var onDone: () -> Void

    @State private var displayName: String
    @State private var profiles: [ChromeProfile] = ChromeProfiles.all()
    @State private var selectedProfile: ChromeProfile?
    @State private var newKey = ""
    @State private var saving = false
    @State private var errorText: String?

    init(model: AppModel, account: Account, onDone: @escaping () -> Void) {
        self.model = model
        self.account = account
        self.onDone = onDone
        _displayName = State(initialValue: account.displayName)
        let all = ChromeProfiles.all()
        _profiles = State(initialValue: all)
        _selectedProfile = State(initialValue: all.first(where: { $0.dir == account.chromeProfileDir }))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit account").font(.system(size: 15, weight: .semibold))
            Text("\(account.orgName) — the organization is fixed; to track a different one, remove this account and add it again.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                Text("Display name").font(.system(size: 11, weight: .medium))
                TextField("", text: $displayName).textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("\(BrowserDetect.current().appName) profile").font(.system(size: 11, weight: .medium))
                Picker("", selection: $selectedProfile) {
                    ForEach(profiles) { p in Text(p.label).tag(Optional(p)) }
                }.labelsHidden()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Replace session key (optional)").font(.system(size: 11, weight: .medium))
                HStack(spacing: 6) {
                    SecureField("Leave blank to keep the current key", text: $newKey)
                        .textFieldStyle(.roundedBorder)
                    Button("Sign in…") {
                        SignInWindow.present { key in newKey = key }
                    }
                    .help("Log in to claude.ai in a window — the key is captured automatically")
                }
            }

            if let errorText {
                Text(errorText).font(.system(size: 11)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button(role: .destructive) {
                    model.removeAccount(account)
                    onDone()
                } label: { Text("Remove account") }
                Spacer()
                Button("Cancel", action: onDone)
                Button(saving ? "Verifying…" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func save() {
        let key = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        errorText = nil
        guard !key.isEmpty else {
            model.updateAccount(id: account.id, displayName: displayName,
                                profile: selectedProfile, newSessionKey: nil)
            onDone()
            return
        }
        saving = true
        Task {
            do {
                // Pre-flight the replacement key against this account's org.
                _ = try await UsageAPI.usage(sessionKey: key, orgUuid: account.orgUuid)
                await MainActor.run {
                    saving = false
                    model.updateAccount(id: account.id, displayName: displayName,
                                        profile: selectedProfile, newSessionKey: key)
                    onDone()
                }
            } catch let e as UsageError {
                await MainActor.run {
                    saving = false
                    errorText = "This key can't read usage for “\(account.orgName)”: \(e.display). Paste a key from the login that owns this account — or remove the account and re-add it."
                }
            } catch {
                await MainActor.run { saving = false; errorText = error.localizedDescription }
            }
        }
    }
}

// MARK: - Preferences

struct PreferencesView: View {
    var model: AppModel
    var onLoginItemToggle: (Bool) -> Void
    var loginItemEnabled: () -> Bool
    var onCheckUpdates: () -> Void

    @State private var pollInterval = Prefs.pollInterval
    @State private var notifyThreshold = Prefs.notifyThreshold
    @State private var notifyOnReset = Prefs.notifyOnReset
    @State private var showRemaining = Prefs.showRemaining
    @State private var sortMode = Prefs.sortMode
    @State private var menuBarMode = Prefs.menuBarMode
    @State private var hotkeyEnabled = Prefs.hotkeyEnabled
    @State private var launchAtLogin = false

    var body: some View {
        Form {
            Section {
                Picker("Refresh every", selection: $pollInterval) {
                    Text("30 seconds").tag(30.0)
                    Text("1 minute").tag(60.0)
                    Text("2 minutes").tag(120.0)
                    Text("5 minutes").tag(300.0)
                }
                Picker("Sort accounts", selection: $sortMode) {
                    ForEach(Prefs.SortMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Menu bar shows", selection: $menuBarMode) {
                    ForEach(Prefs.MenuBarMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("Show remaining % instead of used %", isOn: $showRemaining)
            }
            Section {
                Picker("Notify at", selection: $notifyThreshold) {
                    Text("Off").tag(0)
                    Text("75% of session").tag(75)
                    Text("90% of session").tag(90)
                    Text("95% of session").tag(95)
                }
                Toggle("Notify when a capped session resets", isOn: $notifyOnReset)
            }
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                Toggle("Global hotkey ⌃⌥⌘D toggles the dashboard", isOn: $hotkeyEnabled)
            }
            Section {
                Button("Check for Updates…", action: onCheckUpdates)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { launchAtLogin = loginItemEnabled() }
        .onChange(of: pollInterval) { v in Prefs.pollInterval = v; model.applyPrefsChange() }
        .onChange(of: notifyThreshold) { v in Prefs.notifyThreshold = v }
        .onChange(of: notifyOnReset) { v in Prefs.notifyOnReset = v }
        .onChange(of: showRemaining) { v in Prefs.showRemaining = v; model.objectWillChange.send() }
        .onChange(of: sortMode) { v in Prefs.sortMode = v; model.objectWillChange.send() }
        .onChange(of: menuBarMode) { v in Prefs.menuBarMode = v; model.objectWillChange.send() }
        .onChange(of: hotkeyEnabled) { v in Prefs.hotkeyEnabled = v; model.objectWillChange.send() }
        .onChange(of: launchAtLogin) { v in onLoginItemToggle(v) }
    }
}
