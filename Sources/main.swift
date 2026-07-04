import AppKit
import SwiftUI
import Combine
import ServiceManagement

func dlog(_ s: String) {
    let line = "\(Date()): \(s)\n"
    guard let data = line.data(using: .utf8) else { return }
    let path = "/tmp/claudedash-debug.log"
    if let fh = FileHandle(forWritingAtPath: path) {
        fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
    } else {
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

// MARK: - Floating dashboard panel

final class DashboardPanel: NSPanel {
    init(content: NSView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 340, height: 400),
                   styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        contentView = content
    }

    override var canBecomeKey: Bool { true }
}

// MARK: - App delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var statusItem: NSStatusItem!
    private var panel: DashboardPanel!
    private var hostingView: NSHostingView<DashboardView>!
    private var addWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ note: Notification) {
        // Safety net: a thrown exception during launch would otherwise be swallowed
        // by AppKit, leaving the app running with no menu-bar item and no clue why.
        NSSetUncaughtExceptionHandler { ex in
            dlog("UNCAUGHT EXCEPTION: \(ex.name.rawValue) — \(ex.reason ?? "nil")\n\(ex.callStackSymbols.joined(separator: "\n"))")
        }
        setupPanel()
        setupStatusItem()
        registerLoginItem()
        model.startPolling(interval: 60)

        // Re-render the menu-bar gauges whenever anything changes.
        model.objectWillChange
            .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
            .sink { [weak self] in MainActor.assumeIsolated { self?.renderStatusImage() } }
            .store(in: &cancellables)

        // Re-render immediately when the user flips light/dark mode.
        DistributedNotificationCenter.default.addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.renderStatusImage() } }

        renderStatusImage()
    }

    // MARK: Panel

    private func setupPanel() {
        let root = DashboardView(
            model: model,
            onAdd: { [weak self] in self?.showAddAccount(editing: nil) },
            onFixKey: { [weak self] acct in self?.showAddAccount(editing: acct) }
        )
        hostingView = NSHostingView(rootView: root)
        panel = DashboardPanel(content: hostingView)
    }

    private func togglePanel() {
        if panel.isVisible { panel.orderOut(nil); return }
        // Size to fit content, then anchor under the status item.
        let size = hostingView.fittingSize
        panel.setContentSize(NSSize(width: max(size.width, 340), height: min(max(size.height, 120), 560)))
        positionPanel()
        panel.makeKeyAndOrderFront(nil)
        Task { await model.refreshAll() }
    }

    private func positionPanel() {
        guard let button = statusItem.button, let bwin = button.window else { return }
        let bframe = bwin.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = bwin.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        var x = bframe.midX - panel.frame.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - panel.frame.width - 8)
        let y = bframe.minY - panel.frame.height - 4
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Dash"   // guaranteed-visible fallback until the image renders
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        let rightClick = NSApp.currentEvent?.type == .rightMouseUp
        if rightClick { showStatusMenu() } else { togglePanel() }
    }

    private func showStatusMenu() {
        let menu = NSMenu()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let about = NSMenuItem(title: "Claude Dash v\(version)", action: nil, keyEquivalent: "")
        about.isEnabled = false
        menu.addItem(about)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Dashboard", action: #selector(openDashboard), keyEquivalent: "")
        menu.addItem(withTitle: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Add Account…", action: #selector(addAccountMenu), keyEquivalent: "n")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Claude Dash", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil   // detach so left-click toggles again next time
    }

    /// Self-register as a login item so the dashboard survives reboots.
    private func registerLoginItem() {
        let svc = SMAppService.mainApp
        guard svc.status != .enabled else { return }
        do {
            try svc.register()
            dlog("login item: registered (status now \(svc.status.rawValue))")
        } catch {
            dlog("login item: registration FAILED — \(error)")
        }
    }

    @objc private func openDashboard() { if !panel.isVisible { togglePanel() } }
    @objc private func refreshNow() { Task { await model.refreshAll() } }
    @objc private func addAccountMenu() { showAddAccount(editing: nil) }

    // MARK: Menu bar rendering

    private func renderStatusImage() {
        // The menu bar is usually dark; ImageRenderer defaults to light, which would
        // make the account initials near-invisible. Match the real bar appearance.
        let appearance = statusItem.button?.effectiveAppearance ?? NSApp.effectiveAppearance
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let view = MenuBarGaugesView(accounts: model.accounts, usage: model.usage)
            .frame(height: 18)
            .environment(\.colorScheme, isDark ? .dark : .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        if let image = renderer.nsImage {
            image.isTemplate = false
            statusItem.button?.image = image
            statusItem.button?.imagePosition = .imageOnly
            statusItem.button?.title = ""
        } else {
            statusItem.button?.title = "Dash"   // keep the text fallback if rendering failed
        }
    }

    // MARK: Add-account window

    private func showAddAccount(editing: Account?) {
        if let existing = addWindow { existing.close(); addWindow = nil }
        let view = AddAccountView(model: model, editing: editing) { [weak self] in
            self?.addWindow?.close(); self?.addWindow = nil
            NSApp.setActivationPolicy(.accessory)
        }
        let hosting = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: hosting)
        win.title = editing == nil ? "Add Account" : "Replace Session Key"
        win.styleMask = [.titled, .closable]
        win.isReleasedWhenClosed = false
        win.center()
        addWindow = win
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Bootstrap

// NSApplication.delegate is a weak reference, so hold the delegate strongly here.
private var retainedDelegate: AppDelegate?

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    retainedDelegate = delegate
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
