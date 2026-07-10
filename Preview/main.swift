import AppKit
import SwiftUI

func savePNG(_ image: NSImage, to path: String) -> Bool {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return false }
    return (try? png.write(to: URL(fileURLWithPath: path))) != nil
}

@MainActor
func render<V: View>(_ view: V, _ path: String, scale: CGFloat = 3) {
    let renderer = ImageRenderer(content: view)
    renderer.scale = scale
    if let img = renderer.nsImage, savePNG(img, to: path) {
        print("wrote \(path)  (\(Int(img.size.width))x\(Int(img.size.height)) pt)")
    } else {
        print("FAILED \(path)")
    }
}

MainActor.assumeIsolated {
    let out = ProcessInfo.processInfo.environment["OUT"] ?? "."

    // Generic sample data — these renders ship in the public README.
    let a = Account(id: "a", displayName: "Personal", orgUuid: "1", orgName: "Personal",
                    chromeProfileDir: "Default", chromeProfileLabel: "Personal — alice@example.com")
    let b = Account(id: "b", displayName: "Work", orgUuid: "2", orgName: "Acme Inc",
                    chromeProfileDir: "Profile 1", chromeProfileLabel: "Work — alice@acme.com")
    let c = Account(id: "c", displayName: "Team", orgUuid: "3", orgName: "Acme Team",
                    chromeProfileDir: "Profile 2", chromeProfileLabel: "Team — bot@acme.com")
    let d = Account(id: "d", displayName: "Backup", orgUuid: "4", orgName: "Acme Backup",
                    chromeProfileDir: "Profile 3", chromeProfileLabel: "Backup — spare@acme.com")

    let now = Date()
    let usage: [String: UsageState] = [
        "a": .ok(AccountUsage(session: UsageMetric(utilization: 62, resetsAt: now.addingTimeInterval(6000)),
                              weekly: UsageMetric(utilization: 41, resetsAt: now.addingTimeInterval(400000)),
                              scoped: [ScopedMetric(name: "Fable", metric: UsageMetric(utilization: 12, resetsAt: now.addingTimeInterval(560000)))],
                              fetchedAt: now)),
        "b": .ok(AccountUsage(session: UsageMetric(utilization: 91, resetsAt: now.addingTimeInterval(5400)),
                              weekly: UsageMetric(utilization: 78, resetsAt: now.addingTimeInterval(400000)),
                              scoped: [ScopedMetric(name: "Fable", metric: UsageMetric(utilization: 96, resetsAt: now.addingTimeInterval(560000)))],
                              extra: ExtraUsage(percent: 22, usedDisplay: "4.40 USD used"),
                              fetchedAt: now,
                              projectedCap: now.addingTimeInterval(2700))),
        "c": .problem(.signInRequired),
        // A capped account — session at 100% dims the whole card.
        "d": .ok(AccountUsage(session: UsageMetric(utilization: 100, resetsAt: now.addingTimeInterval(3000)),
                              weekly: UsageMetric(utilization: 64, resetsAt: now.addingTimeInterval(400000)),
                              fetchedAt: now)),
    ]
    let accounts = [a, b, c, d]

    // Menu-bar gauges on a dark bar — mirrors the app's appearance-matched render.
    render(MenuBarGaugesView(accounts: accounts, usage: usage).frame(height: 18).padding(4)
        .environment(\.colorScheme, .dark)
        .background(Color(white: 0.12)), "\(out)/menubar-dark.png", scale: 4)

    // Empty state (before any account is added).
    render(MenuBarGaugesView(accounts: [], usage: [:]).frame(height: 18).padding(4)
        .environment(\.colorScheme, .dark)
        .background(Color(white: 0.12)), "\(out)/menubar-empty.png", scale: 4)

    // The dashboard panel body at its compact/default/largest zoom levels —
    // verifies that the fixed header/footer geometry participates alongside
    // the shared scaled cards, notes, and Claude Code section.
    let sampleNotes: [String: (String, Bool)] = [
        "a": ("- [x] ship v1.2\n- [ ] write release notes", false),
        "b": ("Waiting on legal review before publishing.", true),
    ]
    let ccSessions = [
        CCSession(projectDisplay: "claude-dash", projectDir: "-u-claude-dash",
                  lastActivity: now.addingTimeInterval(-45), waiting: false),
        CCSession(projectDisplay: "webapp", projectDir: "-u-webapp",
                  lastActivity: now.addingTimeInterval(-360), waiting: true),
    ]
    let codexPersonalUsage = CodexUsage(
        windows: [
            CodexWindow(label: "5h", metric: UsageMetric(utilization: 12, resetsAt: now.addingTimeInterval(2 * 3600))),
            CodexWindow(label: "weekly", metric: UsageMetric(utilization: 36, resetsAt: now.addingTimeInterval(4 * 86400))),
        ], planType: "plus", accountEmail: nil, snapshotAt: now.addingTimeInterval(-120))
    let codexTeamUsage = CodexUsage(
        windows: [CodexWindow(label: "monthly",
                              metric: UsageMetric(utilization: 57, resetsAt: now.addingTimeInterval(25 * 86400)))],
        planType: "team", accountEmail: nil, snapshotAt: now.addingTimeInterval(-240))
    let codexAccounts = [
        CodexAccount(id: "codex-personal-preview", nickname: "Personal", email: "you@example.com",
                     planType: "plus", usage: codexPersonalUsage),
        CodexAccount(id: "codex-team-preview", nickname: "TEAM", email: "you@example.com",
                     planType: "team", usage: codexTeamUsage),
    ]

    func panel(_ scheme: ColorScheme, zoom s: CGFloat = 1.0) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8 * s) {
                Text("Claude Dash").font(.system(size: 13 * s, weight: .semibold))
                Spacer()
                Image(systemName: "macwindow").font(.system(size: 12 * s))
                Image(systemName: "gearshape").font(.system(size: 12 * s))
                Image(systemName: "arrow.clockwise").font(.system(size: 12 * s))
            }.padding(.horizontal, 12 * s).padding(.vertical, 8 * s)
            Divider()
            NoteView(text: "Focus this week: launch + KBR sitemap fix",
                     placeholder: "Scratchpad…", onChange: { _ in })
                .padding(.horizontal, 12 * s).padding(.vertical, 8 * s)
            Divider()
            ForEach(accounts) { acct in
                AccountRow(account: acct, state: usage[acct.id] ?? .unknown,
                           noteText: sampleNotes[acct.id]?.0 ?? "",
                           flagged: sampleNotes[acct.id]?.1 ?? false,
                           ccSessions: acct.id == "a" ? ccSessions : [],
                           open: {}, openUsage: {},
                           edit: {}, remove: {}, toggleFlag: {}, noteChanged: { _ in })
                Divider()
            }
            ForEach(codexAccounts) { account in
                CodexSection(account: account, isCurrent: account.id == codexAccounts[0].id,
                             noteText: "- [ ] port the CLI helper")
                Divider()
            }
            HStack {
                Text("Add account…").font(.system(size: 12 * s)).foregroundStyle(.tint)
                Spacer()
                Text("Updated 9:41 PM").font(.system(size: 10 * s)).foregroundStyle(.secondary)
            }.padding(.horizontal, 12 * s).padding(.vertical, 7 * s)
        }
        .frame(width: 340 * s)
        .background(scheme == .dark ? Color(white: 0.13) : Color(white: 0.97))
        .environment(\.colorScheme, scheme)
        .environment(\.dashScale, s)
    }

    render(panel(.light), "\(out)/panel-light.png", scale: 3)
    render(panel(.dark), "\(out)/panel-dark.png", scale: 3)
    render(panel(.dark, zoom: 0.9), "\(out)/panel-90.png", scale: 2)
    render(panel(.dark, zoom: 1.6), "\(out)/panel-160.png", scale: 2)

    // Account-switch safety state: no old rollout is attributed to a newly
    // signed-in account until one new Codex task has produced a fresh file.
    let pendingCodex = CodexAccount(id: "codex-pending-preview", nickname: "Personal",
                                    email: "you@example.com", planType: "plus",
                                    captureAfter: now)
    render(CodexSection(account: pendingCodex, isCurrent: true,
                        noteText: "- [ ] start a fresh task")
        .frame(width: 360)
        .padding(10)
        .background(Color(white: 0.97)), "\(out)/codex-pending.png", scale: 3)

    let staleCodexUsage = CodexUsage(
        windows: [CodexWindow(label: "monthly",
                              metric: UsageMetric(utilization: 57, resetsAt: now.addingTimeInterval(25 * 86400)))],
        planType: "team", accountEmail: nil, snapshotAt: now.addingTimeInterval(-2 * 3600))
    let staleCodex = CodexAccount(id: "codex-stale-preview", nickname: "TEAM",
                                  email: "you@example.com", planType: "team", usage: staleCodexUsage)
    render(CodexSection(account: staleCodex, noteText: "- [ ] refresh this snapshot")
        .frame(width: 360)
        .padding(10)
        .background(Color(white: 0.97)), "\(out)/codex-stale.png", scale: 3)

    // Board window at multiple widths — verifies the adaptive card grid and
    // the zoom environment (the narrow/high-zoom case intentionally becomes
    // one column while the wider case keeps a multi-card grid).
    func board(width: CGFloat, textScale: CGFloat) -> some View {
        BoardContent(accounts: accounts, usage: usage,
                     notes: {
                         var n = NotesData()
                         n.global = "Focus this week: launch + sitemap fix"
                         n.accounts["a"] = AccountNote(text: sampleNotes["a"]!.0, flagged: false)
                         n.accounts["b"] = AccountNote(text: sampleNotes["b"]!.0, flagged: true)
                         n.accounts[NotesData.codexKey(for: codexAccounts[0].id)] = AccountNote(text: "- [ ] personal Codex task")
                         n.accounts[NotesData.codexKey(for: codexAccounts[1].id)] = AccountNote(text: "- [ ] team Codex task")
                         return n
                     }(),
                     ccSessions: [],
                     ccByAccount: ["a": ccSessions], codexAccounts: codexAccounts,
                     codexCurrentAccountID: codexAccounts[0].id, lastRefresh: now,
                     embedInScrollView: false)
            .environment(\.dashScale, textScale)
            .frame(width: width)
            .background(Color(white: 0.14))
            .environment(\.colorScheme, .dark)
    }
    render(board(width: 520, textScale: 1.25), "\(out)/board-narrow.png", scale: 2)
    render(board(width: 900, textScale: 1.25), "\(out)/board-wide.png", scale: 2)
    render(board(width: 720, textScale: 1.6), "\(out)/board-160-narrow.png", scale: 2)
    render(board(width: 1300, textScale: 1.6), "\(out)/board-xl.png", scale: 2)

    // Add-account sheet.
    render(AddAccountView(model: AppModel(), onDone: {})
        .background(Color(white: 0.15))
        .environment(\.colorScheme, .dark), "\(out)/add-account.png", scale: 3)

    // Edit sheet.
    render(EditAccountView(model: AppModel(), account: b, onDone: {})
        .background(Color(white: 0.15))
        .environment(\.colorScheme, .dark), "\(out)/edit-account.png", scale: 3)
}
