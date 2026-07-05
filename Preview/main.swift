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

    // The dashboard panel body (header + rows), light + dark.
    func panel(_ scheme: ColorScheme) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Claude Dash").font(.system(size: 13, weight: .semibold))
                Spacer()
                Image(systemName: "gearshape")
                Image(systemName: "arrow.clockwise")
            }.padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            ForEach(accounts) { acct in
                AccountRow(account: acct, state: usage[acct.id] ?? .unknown,
                           open: {}, openUsage: {}, edit: {}, remove: {})
                Divider()
            }
            HStack {
                Text("Add account…").font(.system(size: 12)).foregroundStyle(.tint)
                Spacer()
                Text("Updated 9:41 PM").font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(.horizontal, 12).padding(.vertical, 7)
        }
        .frame(width: 340)
        .background(scheme == .dark ? Color(white: 0.13) : Color(white: 0.97))
        .environment(\.colorScheme, scheme)
    }

    render(panel(.light), "\(out)/panel-light.png", scale: 3)
    render(panel(.dark), "\(out)/panel-dark.png", scale: 3)

    // Add-account sheet.
    render(AddAccountView(model: AppModel(), onDone: {})
        .background(Color(white: 0.15))
        .environment(\.colorScheme, .dark), "\(out)/add-account.png", scale: 3)

    // Edit sheet.
    render(EditAccountView(model: AppModel(), account: b, onDone: {})
        .background(Color(white: 0.15))
        .environment(\.colorScheme, .dark), "\(out)/edit-account.png", scale: 3)
}
