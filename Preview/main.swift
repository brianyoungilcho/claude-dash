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
        "c": .unauthorized,
    ]
    let accounts = [a, b, c]

    // Menu-bar gauges on a dark bar — mirrors the app's appearance-matched render.
    render(MenuBarGaugesView(accounts: accounts, usage: usage).frame(height: 18).padding(4)
        .environment(\.colorScheme, .dark)
        .background(Color(white: 0.12)), "\(out)/menubar-dark.png", scale: 4)

    // Empty state (before any account is added).
    render(MenuBarGaugesView(accounts: [], usage: [:]).frame(height: 18).padding(4)
        .environment(\.colorScheme, .dark)
        .background(Color(white: 0.12)), "\(out)/menubar-empty.png", scale: 4)

    // The dashboard panel body (header + rows), light + dark — board flavor
    // with notes, flags, and the Claude Code section.
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
    let codexSample = CodexUsage(
        windows: [CodexWindow(label: "monthly",
                              metric: UsageMetric(utilization: 57, resetsAt: now.addingTimeInterval(25 * 86400)))],
        planType: "team",
        accountEmail: "you@example.com",
        snapshotAt: now.addingTimeInterval(-240))

    func panel(_ scheme: ColorScheme) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Claude Dash").font(.system(size: 13, weight: .semibold))
                Spacer()
                Image(systemName: "macwindow")
                Image(systemName: "gearshape")
                Image(systemName: "arrow.clockwise")
            }.padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            NoteView(text: "Focus this week: launch + KBR sitemap fix",
                     placeholder: "Scratchpad…", onChange: { _ in })
                .padding(.horizontal, 12).padding(.vertical, 8)
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
            CodexSection(usage: codexSample)
            Divider()
            HStack {
                Text("Add account…").font(.system(size: 12)).foregroundStyle(.tint)
                Spacer()
                Text("Updated 9:41 PM").font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(.horizontal, 12).padding(.vertical, 7)
        }
        .frame(width: 360)
        .background(scheme == .dark ? Color(white: 0.13) : Color(white: 0.97))
        .environment(\.colorScheme, scheme)
    }

    render(panel(.light), "\(out)/panel-light.png", scale: 3)
    render(panel(.dark), "\(out)/panel-dark.png", scale: 3)

    // Board window at multiple widths — verifies the adaptive card grid and
    // the text-scale environment (Large = 1.25).
    func board(width: CGFloat, textScale: CGFloat) -> some View {
        BoardContent(accounts: accounts, usage: usage,
                     notes: {
                         var n = NotesData()
                         n.global = "Focus this week: launch + sitemap fix"
                         n.accounts["a"] = AccountNote(text: sampleNotes["a"]!.0, flagged: false)
                         n.accounts["b"] = AccountNote(text: sampleNotes["b"]!.0, flagged: true)
                         return n
                     }(),
                     ccSessions: [],
                     ccByAccount: ["a": ccSessions], codex: codexSample, lastRefresh: now,
                     embedInScrollView: false)
            .environment(\.dashScale, textScale)
            .frame(width: width)
            .background(Color(white: 0.14))
            .environment(\.colorScheme, .dark)
    }
    render(board(width: 480, textScale: 1.25), "\(out)/board-narrow.png", scale: 2)
    render(board(width: 900, textScale: 1.25), "\(out)/board-wide.png", scale: 2)
    render(board(width: 1300, textScale: 1.5), "\(out)/board-xl.png", scale: 2)

    // Add-account sheet.
    render(AddAccountView(model: AppModel(), onDone: {})
        .background(Color(white: 0.15))
        .environment(\.colorScheme, .dark), "\(out)/add-account.png", scale: 3)

    // Edit sheet.
    render(EditAccountView(model: AppModel(), account: b, onDone: {})
        .background(Color(white: 0.15))
        .environment(\.colorScheme, .dark), "\(out)/edit-account.png", scale: 3)
}
