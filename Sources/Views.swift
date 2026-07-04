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
    }
}

/// One compact metric row: fixed-width label, small bar, percent, reset time.
struct MetricLine: View {
    var label: String
    var metric: UsageMetric

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
                .lineLimit(1)
            UsageBar(pct: metric.utilization, height: 4)
            Text("\(Int(metric.utilization))%")
                .font(.system(size: 9, weight: .medium)).monospacedDigit()
                .foregroundStyle(usageColor(metric.utilization))
                .frame(width: 30, alignment: .trailing)
            Text(resetString(metric.resetsAt))
                .font(.system(size: 8)).foregroundStyle(.secondary)
                .frame(width: 76, alignment: .trailing)
                .lineLimit(1)
        }
    }
}

// MARK: - Dashboard panel

struct DashboardView: View {
    @ObservedObject var model: AppModel
    var onAdd: () -> Void
    var onFixKey: (Account) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.accounts.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.accounts) { account in
                            AccountRow(
                                account: account,
                                state: model.usage[account.id] ?? .unknown,
                                open: { model.openChrome(account, path: "/new") },
                                openUsage: { model.openChrome(account, path: "/settings/usage") },
                                fixKey: { onFixKey(account) },
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
        .frame(maxHeight: 520)
    }

    private var header: some View {
        HStack {
            Text("Claude Dash").font(.system(size: 13, weight: .semibold))
            Spacer()
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
            Text("Add a Claude account to see its usage and jump into the right Chrome profile.")
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
    var fixKey: () -> Void
    var remove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
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
            Button(action: open) {
                Text("Open").font(.system(size: 11, weight: .medium))
            }
            .controlSize(.small)
            .help("Open claude.ai in \(account.chromeProfileLabel)")
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .contextMenu {
            Button("Open claude.ai", action: open)
            Button("Open usage page", action: openUsage)
            Divider()
            Button("Replace session key…", action: fixKey)
            Button("Remove account", role: .destructive, action: remove)
        }
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
                    Text("\(Int(session))%")
                        .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(usageColor(session))
                }
                UsageBar(pct: session)
                // Weekly + per-model caps (e.g. Fable) — compact aligned lines.
                if let weekly = u.weekly {
                    MetricLine(label: "Weekly", metric: weekly)
                }
                ForEach(u.scoped, id: \.name) { s in
                    MetricLine(label: s.name, metric: s.metric)
                }
            }
        case .loading, .unknown:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading…").font(.system(size: 11)).foregroundStyle(.secondary)
            }.frame(height: 20)
        case .unauthorized:
            Button(action: fixKey) {
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

    var body: some View {
        HStack(spacing: 7) {
            if accounts.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "gauge.with.dots.needle.33percent")
                        .font(.system(size: 13, weight: .medium))
                    Text("Dash").font(.system(size: 11, weight: .semibold))
                }
            } else {
                ForEach(accounts) { a in chip(a) }
            }
        }
        .padding(.horizontal, 2)
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

// MARK: - Add / edit account

struct AddAccountView: View {
    @ObservedObject var model: AppModel
    /// If set, we're replacing the key for an existing account.
    var editing: Account?
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

    private var isEditing: Bool { editing != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isEditing ? "Replace session key" : "Add Claude account")
                .font(.system(size: 15, weight: .semibold))

            VStack(alignment: .leading, spacing: 4) {
                Text("Session key").font(.system(size: 11, weight: .medium))
                SecureField("sk-ant-sid01-…", text: $sessionKey)
                    .textFieldStyle(.roundedBorder)
                Text("In the right Chrome profile: open claude.ai → DevTools (⌥⌘I) → Application → Cookies → https://claude.ai → copy the sessionKey value.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let errorText {
                Text(errorText).font(.system(size: 11)).foregroundStyle(.red)
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
            }

            if !isEditing && !orgs.isEmpty {
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
                    Button(committing ? "Verifying usage…" : (isEditing ? "Save key" : "Add account"), action: commit)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canCommit || committing)
                }
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private var canCommit: Bool {
        guard selectedOrg != nil else { return false }
        if isEditing { return true }
        return selectedProfile != nil
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
        // Pre-flight: prove the usage endpoint answers for THIS key + org before
        // saving, so a wrong-org pick fails here with the real reason instead of
        // as a permanent "expired" row.
        let orgUuid = editing?.orgUuid ?? selectedOrg?.uuid
        guard let orgUuid else { return }
        errorText = nil
        committing = true
        Task {
            do {
                _ = try await UsageAPI.usage(sessionKey: key, orgUuid: orgUuid)
                await MainActor.run {
                    committing = false
                    if let editing {
                        model.updateKey(accountId: editing.id, sessionKey: key)
                    } else if let org = selectedOrg, let profile = selectedProfile {
                        model.addAccount(sessionKey: key, org: org, profile: profile, displayName: displayName)
                    }
                    onDone()
                }
            } catch let e as UsageError {
                await MainActor.run {
                    committing = false
                    let orgName = editing?.orgName ?? selectedOrg?.name ?? "this organization"
                    errorText = "Usage check failed for “\(orgName)”: \(e.display)." +
                        (orgs.count > 1 ? " Try a different organization from the list." : "")
                }
            } catch {
                await MainActor.run { committing = false; errorText = error.localizedDescription }
            }
        }
    }
}
