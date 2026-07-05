import AppKit
import SwiftUI
import Combine
import ServiceManagement
import Carbon.HIToolbox

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

let repoURL = "https://github.com/brianyoungilcho/claude-dash"

// MARK: - Floating dashboard panel

final class DashboardPanel: NSPanel {
    /// All dismissals must run through the owner's hidePanel() so the global
    /// outside-click monitor is torn down on every path, including Esc.
    var onDismiss: (() -> Void)?

    init(content: NSView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 340, height: 400),
                   styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = content
    }

    override var canBecomeKey: Bool { true }

    /// Pinned boards ignore Esc; popovers dismiss.
    var pinned = false

    override func cancelOperation(_ sender: Any?) {
        guard !pinned else { return }
        if let onDismiss { onDismiss() } else { orderOut(nil) }
    }
}

// MARK: - Carbon hotkey trampoline (C callback can't capture context)

private func hotKeyHandler(_ next: EventHandlerCallRef?, _ event: EventRef?,
                           _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let userData else { return noErr }
    let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
    DispatchQueue.main.async { delegate.hotkeyFired() }
    return noErr
}

// MARK: - App delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var statusItem: NSStatusItem!
    private var panel: DashboardPanel!
    private var hostingView: NSHostingView<DashboardView>!
    private var auxWindows: [NSWindow] = []
    private var cancellables = Set<AnyCancellable>()
    private var outsideClickMonitor: Any?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerInstalled = false

    func applicationDidFinishLaunching(_ note: Notification) {
        // Safety net: a thrown exception during launch would otherwise be swallowed
        // by AppKit, leaving the app running with no menu-bar item and no clue why.
        NSSetUncaughtExceptionHandler { ex in
            dlog("UNCAUGHT EXCEPTION: \(ex.name.rawValue) — \(ex.reason ?? "nil")\n\(ex.callStackSymbols.joined(separator: "\n"))")
        }
        setupPanel()
        setupStatusItem()
        registerLoginItemOnce()
        syncHotkey()
        model.startPolling()

        // Re-render the menu-bar gauges (and re-sync the hotkey) on any change.
        model.objectWillChange
            .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
            .sink { [weak self] in
                MainActor.assumeIsolated {
                    self?.renderStatusImage()
                    self?.syncHotkey()
                    self?.applyPinState()
                    self?.resizePanelIfNeeded()
                }
            }
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
            onAdd: { [weak self] in self?.showAddAccount() },
            onEdit: { [weak self] acct in self?.showEdit(acct) },
            onPrefs: { [weak self] in self?.showPreferences() }
        )
        hostingView = NSHostingView(rootView: root)
        panel = DashboardPanel(content: hostingView)
        panel.onDismiss = { [weak self] in self?.hidePanel() }
        applyPinState(initial: true)
    }

    /// Popover mode: auto-sized, dismiss-on-outside-click, floats.
    /// Board mode: resizable, persistent, remembers its frame, optional float.
    private func applyPinState(initial: Bool = false) {
        let pinned = model.boardPinned
        guard panel.pinned != pinned || initial else {
            // Pin unchanged — but the float preference may have flipped.
            if pinned { panel.level = Prefs.boardFloats ? .floating : .normal }
            return
        }
        panel.pinned = pinned
        if pinned {
            panel.styleMask.insert(.resizable)
            panel.level = Prefs.boardFloats ? .floating : .normal
            panel.setFrameAutosaveName("ClaudeDashBoard")
            if !initial {
                if let m = outsideClickMonitor { NSEvent.removeMonitor(m); outsideClickMonitor = nil }
                if !panel.isVisible { panel.makeKeyAndOrderFront(nil) }
            }
        } else {
            panel.styleMask.remove(.resizable)
            panel.level = .floating
            panel.setFrameAutosaveName("")   // popover position is computed, not remembered
            if !initial, panel.isVisible {
                // Snap back to compact popover under the status item.
                let size = hostingView.fittingSize
                panel.setContentSize(NSSize(width: 340, height: min(max(size.height, 120), 560)))
                positionPanel()
                if outsideClickMonitor == nil { installOutsideClickMonitor() }
            }
        }
    }

    private func togglePanel() {
        panel.isVisible ? hidePanel() : showPanel()
    }

    private func showPanel() {
        if model.boardPinned {
            // Board: restore the remembered frame; user controls size/position.
            panel.makeKeyAndOrderFront(nil)
        } else {
            let size = hostingView.fittingSize
            panel.setContentSize(NSSize(width: max(size.width, 340), height: min(max(size.height, 120), 600)))
            positionPanel()
            panel.makeKeyAndOrderFront(nil)
            if outsideClickMonitor == nil { installOutsideClickMonitor() }
        }
        Task { await model.refreshAll() }
        model.refreshClaudeCode()
    }

    /// Clicks in OTHER apps (i.e. outside the panel) dismiss the popover — the
    /// native menu-bar feel. Never installed in board mode.
    private func installOutsideClickMonitor() {
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hidePanel() }
        }
    }

    private func hidePanel() {
        panel.orderOut(nil)
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m); outsideClickMonitor = nil }
    }

    /// Keep the visible POPOVER sized to its content — rows appear, disappear,
    /// and grow while it's open. Pinned boards are user-sized; never fight them.
    private func resizePanelIfNeeded() {
        guard panel.isVisible, !model.boardPinned else { return }
        let size = hostingView.fittingSize
        let target = NSSize(width: max(size.width, 340), height: min(max(size.height, 120), 600))
        guard abs(panel.frame.height - target.height) > 2 || abs(panel.frame.width - target.width) > 2 else { return }
        let top = panel.frame.maxY
        panel.setContentSize(target)
        panel.setFrameOrigin(NSPoint(x: panel.frame.origin.x, y: top - panel.frame.height))
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
        let event = NSApp.currentEvent
        let secondary = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) ?? false)   // Control-click = secondary click
        if secondary { showStatusMenu() } else { togglePanel() }
    }

    private func showStatusMenu() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let menu = NSMenu()
        menu.addItem(withTitle: "About Claude Dash (v\(version))", action: #selector(openAbout), keyEquivalent: "")
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        menu.addItem(withTitle: "Preferences…", action: #selector(openPreferences), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Dashboard", action: #selector(openDashboard), keyEquivalent: "")
        menu.addItem(withTitle: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        menu.addItem(withTitle: "Add Account…", action: #selector(addAccountMenu), keyEquivalent: "n")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Claude Dash", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil   // detach so left-click toggles again next time
    }

    @objc private func openAbout() { NSWorkspace.shared.open(URL(string: repoURL)!) }
    @objc private func openDashboard() { if !panel.isVisible { showPanel() } }
    @objc private func refreshNow() { Task { await model.refreshAll() } }
    @objc private func addAccountMenu() { showAddAccount() }
    @objc private func openPreferences() { showPreferences() }

    func hotkeyFired() { togglePanel() }

    // MARK: Update check (plain GitHub Releases — no Sparkle)

    @objc func checkForUpdates() {
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/brianyoungilcho/claude-dash/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            var latest: String?, url: String?
            if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                latest = (obj["tag_name"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
                url = obj["html_url"] as? String
            }
            DispatchQueue.main.async {
                let alert = NSAlert()
                if let latest {
                    let upToDate = latest.compare(current, options: .numeric) != .orderedDescending
                    alert.messageText = upToDate ? "You're up to date" : "Update available: v\(latest)"
                    alert.informativeText = upToDate
                        ? "Claude Dash v\(current) is the latest release."
                        : "You have v\(current). Download v\(latest) from GitHub, or run git pull && ./install.sh."
                    alert.addButton(withTitle: upToDate ? "OK" : "Open Releases")
                    if !upToDate { alert.addButton(withTitle: "Later") }
                    if alert.runModal() == .alertFirstButtonReturn, !upToDate, let url, let u = URL(string: url) {
                        NSWorkspace.shared.open(u)
                    }
                } else {
                    alert.messageText = "Couldn't check for updates"
                    alert.informativeText = "GitHub wasn't reachable. Try again later."
                    alert.runModal()
                }
            }
        }.resume()
    }

    // MARK: Menu bar rendering

    private func renderStatusImage() {
        // The menu bar is usually dark; ImageRenderer defaults to light, which would
        // make the account initials near-invisible. Match the real bar appearance.
        let appearance = statusItem.button?.effectiveAppearance ?? NSApp.effectiveAppearance
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let view = MenuBarGaugesView(accounts: model.accounts, usage: model.usage,
                                     mode: Prefs.menuBarMode, attention: model.anyAttention)
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

    // MARK: Login item

    /// Auto-register once so the dashboard survives reboots; afterwards the
    /// user's System Settings / Preferences choice is authoritative.
    private func registerLoginItemOnce() {
        let flag = "didAutoRegisterLoginItem"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        do {
            if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            UserDefaults.standard.set(true, forKey: flag)
        } catch {
            dlog("login item: registration FAILED — \(error)")
        }
    }

    private func setLoginItem(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            dlog("login item toggle FAILED — \(error)")
        }
    }

    // MARK: Global hotkey (⌃⌥⌘D)

    private func syncHotkey() {
        if Prefs.hotkeyEnabled, hotKeyRef == nil {
            if !hotKeyHandlerInstalled {
                var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                              eventKind: UInt32(kEventHotKeyPressed))
                InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &eventType,
                                    Unmanaged.passUnretained(self).toOpaque(), nil)
                hotKeyHandlerInstalled = true
            }
            let hotKeyID = EventHotKeyID(signature: OSType(0x43_44_41_53) /* CDAS */, id: 1)
            RegisterEventHotKey(UInt32(kVK_ANSI_D),
                                UInt32(cmdKey | optionKey | controlKey),
                                hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        } else if !Prefs.hotkeyEnabled, let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    // MARK: Aux windows (add / edit / preferences)

    private func showAddAccount() {
        presentAuxWindow(title: "Add Account") { done in
            AnyView(AddAccountView(model: model, onDone: done))
        }
    }

    private func showEdit(_ account: Account) {
        presentAuxWindow(title: "Edit Account") { done in
            AnyView(EditAccountView(model: model, account: account, onDone: done))
        }
    }

    private func showPreferences() {
        presentAuxWindow(title: "Preferences") { _ in
            AnyView(PreferencesView(
                model: model,
                onLoginItemToggle: { [weak self] on in self?.setLoginItem(on) },
                loginItemEnabled: { SMAppService.mainApp.status == .enabled },
                onCheckUpdates: { [weak self] in self?.checkForUpdates() }
            ))
        }
    }

    /// Present a standard window for a SwiftUI view, flipping to a regular app
    /// (Dock icon) while any aux window is open. The willClose observer is the
    /// single cleanup path, so the red close button, Cancel, and success all
    /// restore the accessory policy identically.
    private final class WeakWindowBox { weak var window: NSWindow? }

    private func presentAuxWindow(title: String, _ make: (@escaping () -> Void) -> AnyView) {
        // Single instance per dialog: focus the existing window instead of
        // stacking duplicates with divergent state snapshots.
        if let existing = auxWindows.first(where: { $0.title == title }) {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }
        // The onDone closure must hold the window WEAKLY, or the window's own
        // view hierarchy retains it forever (window → hosting → view → closure).
        let box = WeakWindowBox()
        let view = make { box.window?.close() }
        let win = NSWindow(contentViewController: NSHostingController(rootView: view))
        box.window = win
        win.title = title
        win.styleMask = [.titled, .closable]
        win.isReleasedWhenClosed = false
        win.center()
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: win, queue: .main
        ) { [weak self] note in
            if let token { NotificationCenter.default.removeObserver(token) }
            token = nil
            MainActor.assumeIsolated {
                guard let self else { return }
                self.auxWindows.removeAll { $0 === (note.object as? NSWindow) }
                if self.auxWindows.isEmpty { NSApp.setActivationPolicy(.accessory) }
            }
        }
        auxWindows.append(win)
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
