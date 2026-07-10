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

    /// Esc dismisses the popover.
    override func cancelOperation(_ sender: Any?) {
        if let onDismiss { onDismiss() } else { orderOut(nil) }
    }

    /// ⌘W (Window ▸ Close targets the key window) should dismiss the popover
    /// instead of beeping — the panel has no .closable style bit.
    override func performClose(_ sender: Any?) {
        if let onDismiss { onDismiss() } else { orderOut(nil) }
    }
}

/// A titled panel (even with a hidden, transparent titlebar) reports its ~28pt
/// titlebar as a top safe-area inset. NSHostingView honors that inset and lays
/// the SwiftUI content out below it, leaving dead space above the popover's
/// header. Zeroing the insets lets the content sit flush with the top edge.
final class EdgeToEdgeHostingView<Content: View>: NSHostingView<Content> {
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsets() }
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
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private enum ZoomSurface { case quickGlance, board }

    let model = AppModel()
    private let updateManager = UpdateManager()
    private var statusItem: NSStatusItem!
    private var panel: DashboardPanel!
    private var hostingView: NSHostingView<DashboardView>!
    private var auxWindows: [String: NSWindow] = [:]   // keyed by dialog identity
    private var boardWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var outsideClickMonitor: Any?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerInstalled = false
    private var localZoomEventMonitor: Any?
    private var sigtermSource: DispatchSourceSignal?
    private var statusWatchdog: Timer?
    /// AppKit closes all windows DURING terminate teardown (after
    /// applicationWillTerminate), which would run the board's willClose
    /// observer and falsely record "user closed the board."
    private var isTerminating = false

    func applicationDidFinishLaunching(_ note: Notification) {
        // Safety net: a thrown exception during launch would otherwise be swallowed
        // by AppKit, leaving the app running with no menu-bar item and no clue why.
        NSSetUncaughtExceptionHandler { ex in
            dlog("UNCAUGHT EXCEPTION: \(ex.name.rawValue) — \(ex.reason ?? "nil")\n\(ex.callStackSymbols.joined(separator: "\n"))")
        }
        setupMainMenu()
        setupPanel()
        setupStatusItem()
        updateManager.start()
        registerLoginItemOnce()
        syncHotkey()
        installZoomShortcutMonitor()
        model.startPolling()
        if Prefs.boardWasOpen { openBoardWindow() }

        // Re-render the menu-bar gauges (and re-sync the hotkey) on any change.
        model.objectWillChange
            .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
            .sink { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.renderStatusImage()
                    self.syncHotkey()
                    // Float preference may have changed in Preferences.
                    self.boardWindow?.level = Prefs.boardFloats ? .floating : .normal
                    self.syncBoardGeometry()
                    self.resizePanelIfNeeded()
                }
            }
            .store(in: &cancellables)

        // Notes must survive every exit path: normal quit (willTerminate) and
        // SIGTERM (pkill during ./install.sh upgrades).
        signal(SIGTERM, SIG_IGN)
        sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigtermSource?.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.model.flushNotesNow() }
            NSApp.terminate(nil)
        }
        sigtermSource?.resume()

        // Re-render immediately when the user flips light/dark mode.
        DistributedNotificationCenter.default.addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.renderStatusImage() } }

        // macOS 26 (Tahoe) can silently evict a long-lived status item after
        // hours — the app stays healthy but the icon vanishes. Nothing re-adds it
        // on its own, so poll for its window and rebuild when it's gone. First
        // fire is +60s so the normal startup attach is never misread as eviction;
        // the 60s cadence also rate-limits us so a rebuild can't thrash.
        statusWatchdog = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.verifyStatusItem() }
        }

        // The poll timer doesn't fire while the Mac sleeps and only catches up on
        // its next interval, so the bar shows stale data right after wake —
        // refresh now. Status-item eviction also tends to surface after sleep, so
        // re-check the item here too. (Workspace notifications post on their own
        // center, not NotificationCenter.default.)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.verifyStatusItem()
                Task { await self.model.refreshAll() }
                self.model.refreshClaudeCode()
                self.model.refreshCodex()
            }
        }

        renderStatusImage()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        isTerminating = true
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        if let monitor = localZoomEventMonitor {
            NSEvent.removeMonitor(monitor)
            localZoomEventMonitor = nil
        }
        model.flushNotesNow()
    }

    /// A Dock-icon click (or `open` on the already-running app) sends this.
    /// As an LSUIElement/accessory app we own no default window, so without a
    /// handler AppKit does nothing and the Dock icon looks dead. Surface the
    /// board: if any window is already visible, just bring the app forward;
    /// otherwise open (or deminiaturize) the board. We target the board, not the
    /// popover panel, because the panel is anchored to the menu-bar status item —
    /// which macOS may be hiding, leaving the panel with nowhere valid to appear.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if flag {
            NSApp.activate(ignoringOtherApps: true)
        } else {
            openBoardWindow()
        }
        return true
    }

    // MARK: Panel

    private func setupPanel() {
        let root = DashboardView(
            model: model,
            onAdd: { [weak self] in self?.showAddAccount() },
            onEdit: { [weak self] acct in self?.showEdit(acct) },
            onPrefs: { [weak self] in self?.showPreferences() },
            onRemove: { [weak self] acct in self?.confirmRemove(acct) },
            onOpenBoard: { [weak self] in
                self?.hidePanel()
                self?.openBoardWindow()
            }
        )
        hostingView = EdgeToEdgeHostingView(rootView: root)
        panel = DashboardPanel(content: hostingView)
        panel.onDismiss = { [weak self] in self?.hidePanel() }
    }

    private func togglePanel() {
        panel.isVisible ? hidePanel() : showPanel()
    }

    private func showPanel() {
        panel.setContentSize(fittingPanelSize())
        positionPanel()
        panel.makeKeyAndOrderFront(nil)
        if outsideClickMonitor == nil { installOutsideClickMonitor() }
        Task { await model.refreshAll() }
        model.refreshClaudeCode()
        model.refreshCodex()
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
        // End any in-progress note edit first — an ordered-out window keeps its
        // first responder, so without this a hidden editor would sit on a stale
        // draft while the board edits the same note.
        panel.makeFirstResponder(nil)
        panel.orderOut(nil)
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m); outsideClickMonitor = nil }
    }

    /// Keep the visible popover sized to its content — rows appear, disappear,
    /// and grow while it's open. Zoomed Quick Glance content is clamped to the
    /// current screen rather than growing offscreen.
    private func resizePanelIfNeeded() {
        guard panel.isVisible else { return }
        let target = fittingPanelSize()
        guard abs(panel.frame.height - target.height) > 2 || abs(panel.frame.width - target.width) > 2 else { return }
        panel.setContentSize(target)
        // A larger size can put the old center past a display edge; always
        // re-anchor beneath the status item after a zoom/layout change.
        positionPanel()
    }

    private func panelVisibleFrame() -> NSRect {
        if let screen = statusItem?.button?.window?.screen ?? panel?.screen ?? NSScreen.main {
            return screen.visibleFrame
        }
        // Only used before AppKit has attached a screen. A non-zero fallback
        // keeps the sizing math well-defined until the next run-loop pass.
        return NSRect(x: 0, y: 0, width: 800, height: 600)
    }

    private func fittingPanelSize() -> NSSize {
        let fitting = hostingView.fittingSize
        let visible = panelVisibleFrame()
        let maxWidth = max(1, visible.width - 16)
        let maxHeight = max(1, visible.height - 16)
        return NSSize(width: min(max(fitting.width, 280), maxWidth),
                      height: min(max(fitting.height, 120), maxHeight))
    }

    private func positionPanel() {
        guard let button = statusItem.button, let bwin = button.window else { return }
        let bframe = bwin.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = bwin.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? panelVisibleFrame()
        let margin: CGFloat = 8
        let minX = visible.minX + margin
        let maxX = max(minX, visible.maxX - panel.frame.width - margin)
        let x = min(max(bframe.midX - panel.frame.width / 2, minX), maxX)
        let minY = visible.minY + margin
        let maxY = max(minY, visible.maxY - panel.frame.height - margin)
        let y = min(max(bframe.minY - panel.frame.height - 4, minY), maxY)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: Board window (a real, resizable macOS window)

    @objc func openBoardWindow() {
        if let win = boardWindow {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            if win.isMiniaturized { win.deminiaturize(nil) }
            win.makeKeyAndOrderFront(nil)
            return
        }
        let view = BoardView(
            model: model,
            onAdd: { [weak self] in self?.showAddAccount() },
            onEdit: { [weak self] acct in self?.showEdit(acct) },
            onPrefs: { [weak self] in self?.showPreferences() },
            onRemove: { [weak self] acct in self?.confirmRemove(acct) }
        )
        let win = NSWindow(contentViewController: NSHostingController(rootView: view))
        win.title = "Claude Dash"
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.isReleasedWhenClosed = false
        // `syncBoardGeometry()` below applies the current zoom-aware minimum
        // once the restored/default frame is in place.
        win.minSize = NSSize(width: 400, height: 320)
        win.level = Prefs.boardFloats ? .floating : .normal
        if !win.setFrameUsingName("ClaudeDashBoardWindow") {
            win.setContentSize(NSSize(width: 820, height: 640))
            win.center()
        }
        win.setFrameAutosaveName("ClaudeDashBoardWindow")
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: win, queue: .main
        ) { [weak self] _ in
            if let token { NotificationCenter.default.removeObserver(token) }
            token = nil
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.flushNotesNow()
                // Only a USER close means "don't reopen at launch" — teardown
                // closes during quit must leave the reopen state intact.
                guard !self.isTerminating else { return }
                self.boardWindow = nil
                Prefs.boardWasOpen = false
                if self.auxWindows.isEmpty { NSApp.setActivationPolicy(.accessory) }
            }
        }
        boardWindow = win
        syncBoardGeometry()
        Prefs.boardWasOpen = true
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        Task { await model.refreshAll() }
        model.refreshClaudeCode()
        model.refreshCodex()
    }

    /// Board cards need a larger minimum usable area at larger zoom levels.
    /// Keep that minimum inside the current display and clamp restored frames
    /// back onscreen, so a scale change never leaves an unreachable window.
    private func syncBoardGeometry() {
        guard let win = boardWindow else { return }
        let visible = (win.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let margin: CGFloat = 12
        let maximum = NSSize(width: max(1, visible.width - margin * 2),
                             height: max(1, visible.height - margin * 2))
        let scale = CGFloat(Prefs.boardTextScale)
        let desiredMinimum = NSSize(width: 400 * scale, height: 320 * scale)
        let minimum = NSSize(width: min(desiredMinimum.width, maximum.width),
                             height: min(desiredMinimum.height, maximum.height))
        win.minSize = minimum

        let current = win.contentView?.bounds.size ?? win.contentLayoutRect.size
        let target = NSSize(width: min(max(current.width, minimum.width), maximum.width),
                            height: min(max(current.height, minimum.height), maximum.height))
        if abs(current.width - target.width) > 1 || abs(current.height - target.height) > 1 {
            win.setContentSize(target)
        }
        clampBoardWindow(win, to: visible, margin: margin)
    }

    private func clampBoardWindow(_ win: NSWindow, to visible: NSRect, margin: CGFloat = 8) {
        let frame = win.frame
        let minX = visible.minX + margin
        let maxX = max(minX, visible.maxX - frame.width - margin)
        let minY = visible.minY + margin
        let maxY = max(minY, visible.maxY - frame.height - margin)
        win.setFrameOrigin(NSPoint(x: min(max(frame.origin.x, minX), maxX),
                                   y: min(max(frame.origin.y, minY), maxY)))
    }

    private func toggleBoardWindow() {
        if let win = boardWindow, win.isVisible, !win.isMiniaturized {
            if win.isKeyWindow {
                win.performClose(nil)
            } else {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                win.makeKeyAndOrderFront(nil)
            }
        } else {
            openBoardWindow()   // also deminiaturizes an existing window
        }
    }

    // MARK: Main menu — an LSUIElement app has none by default, which silently
    // breaks ⌘C/⌘V/⌘A in every text field and ⌘W on windows.

    private func setupMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        let about = NSMenuItem(title: "About Claude Dash", action: #selector(openAbout), keyEquivalent: "")
        about.target = self
        appMenu.addItem(about)
        let prefs = NSMenuItem(title: "Settings…", action: #selector(openPreferences), keyEquivalent: ",")
        prefs.target = self
        appMenu.addItem(prefs)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Claude Dash",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        // File — makes the ⌘N / ⌘R shown in the status menu actually fire when
        // a Claude Dash window is frontmost.
        let fileItem = NSMenuItem(); main.addItem(fileItem)
        let file = NSMenu(title: "File")
        let add = NSMenuItem(title: "Add Account…", action: #selector(addAccountMenu), keyEquivalent: "n")
        add.target = self
        file.addItem(add)
        let refresh = NSMenuItem(title: "Refresh", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        file.addItem(refresh)
        fileItem.submenu = file

        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        // View — native menu key equivalents make ⌘+/⌘−/⌘0 work in the
        // focused dashboard without registering any global shortcut.
        let viewItem = NSMenuItem(); main.addItem(viewItem)
        let view = NSMenu(title: "View")
        let zoomIn = NSMenuItem(title: "Zoom In", action: #selector(zoomIn(_:)), keyEquivalent: "+")
        zoomIn.keyEquivalentModifierMask = [.command]
        zoomIn.target = self
        view.addItem(zoomIn)
        let zoomOut = NSMenuItem(title: "Zoom Out", action: #selector(zoomOut(_:)), keyEquivalent: "-")
        zoomOut.keyEquivalentModifierMask = [.command]
        zoomOut.target = self
        view.addItem(zoomOut)
        let actualSize = NSMenuItem(title: "Actual Size", action: #selector(actualSize(_:)), keyEquivalent: "0")
        actualSize.keyEquivalentModifierMask = [.command]
        actualSize.target = self
        view.addItem(actualSize)
        viewItem.submenu = view

        let windowItem = NSMenuItem(); main.addItem(windowItem)
        let window = NSMenu(title: "Window")
        let board = NSMenuItem(title: "Claude Dash Board", action: #selector(openBoardWindow), keyEquivalent: "b")
        board.target = self
        window.addItem(board)
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = window

        NSApp.mainMenu = main
    }

    // MARK: Status item

    private func setupStatusItem() {
        // macOS 26 notched-menu-bar fix: a status item with no persisted
        // position gets dropped into the left-of-notch overflow region and is
        // NEVER drawn — the app runs fine but the icon is invisible. Seed a
        // right-of-notch slot (only if we've never recorded one) BEFORE giving
        // the item its autosave name, so macOS restores a visible position on
        // first launch. The moment the user drags the icon, macOS overwrites
        // this key, so we never fight a manual placement. Verified live on
        // macOS 26.5.1: without this the item sits at x≈632 (hidden); with it,
        // x≈975 (visible, clickable).
        let posKey = "NSStatusItem Preferred Position ClaudeDashStatusItem"
        if UserDefaults.standard.object(forKey: posKey) == nil {
            UserDefaults.standard.set(450.0, forKey: posKey)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "ClaudeDashStatusItem"
        statusItem.button?.title = "Dash"   // guaranteed-visible fallback until the image renders
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    /// Rebuild the status item if macOS 26 has evicted it. A healthy long-lived
    /// item keeps its `button.window`; that going nil is the reliable eviction
    /// signal (`isVisible` can lie). Called by the watchdog timer and on wake.
    private func verifyStatusItem() {
        if statusItem != nil, statusItem.button?.window != nil { return }
        if let existing = statusItem { NSStatusBar.system.removeStatusItem(existing) }
        setupStatusItem()
        renderStatusImage()
        dlog("status item was evicted; re-added")
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
        menu.addItem(withTitle: "Settings…", action: #selector(openPreferences), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Board Window", action: #selector(openBoardWindow), keyEquivalent: "b")
        menu.addItem(withTitle: "Open Quick Glance", action: #selector(openDashboard), keyEquivalent: "")
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
    @objc private func refreshNow() { Task { await model.userRefresh() } }
    @objc private func addAccountMenu() { showAddAccount() }
    @objc private func openPreferences() { showPreferences() }

    // MARK: Dashboard zoom

    /// Command shortcuts live in the View menu, so they remain app-local and
    /// continue to work while a note's text editor owns first responder.
    @objc private func zoomIn(_ sender: Any?) { adjustZoom(.increase) }
    @objc private func zoomOut(_ sender: Any?) { adjustZoom(.decrease) }
    @objc private func actualSize(_ sender: Any?) { adjustZoom(.reset) }

    private func activeDashboardSurface() -> (surface: ZoomSurface, window: NSWindow)? {
        if let boardWindow, boardWindow.isKeyWindow || NSApp.keyWindow === boardWindow {
            return (.board, boardWindow)
        }
        if panel.isVisible, panel.isKeyWindow || NSApp.keyWindow === panel {
            return (.quickGlance, panel)
        }
        return nil
    }

    private func adjustZoom(_ direction: DashboardZoom.Direction) {
        guard let active = activeDashboardSurface() else { return }
        switch active.surface {
        case .quickGlance:
            let next = DashboardZoom.adjusted(Prefs.quickGlanceTextScale,
                                              direction: direction,
                                              default: DashboardZoom.quickGlanceDefault)
            guard next != Prefs.quickGlanceTextScale else { return }
            Prefs.quickGlanceTextScale = next
        case .board:
            let next = DashboardZoom.adjusted(Prefs.boardTextScale,
                                              direction: direction,
                                              default: DashboardZoom.boardDefault)
            guard next != Prefs.boardTextScale else { return }
            Prefs.boardTextScale = next
        }
        // Both roots observe this model. Publish once so Preferences, a visible
        // panel, and a visible board redraw in the same run-loop turn.
        model.objectWillChange.send()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.syncBoardGeometry()
            self.resizePanelIfNeeded()
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(zoomIn(_:)), #selector(zoomOut(_:)), #selector(actualSize(_:)):
            return activeDashboardSurface() != nil
        default:
            return true
        }
    }

    /// The requested Option aliases are deliberately a local event monitor:
    /// they only see events delivered to Claude Dash, and never register a
    /// system-wide hotkey. Option+Shift is allowed for the physical `+` key on
    /// layouts where plus requires Shift. Any text editor wins so Option input
    /// (including non-US/Korean layouts and IME composition) is untouched.
    private func installZoomShortcutMonitor() {
        guard localZoomEventMonitor == nil else { return }
        localZoomEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Move only value types across the MainActor boundary. `NSEvent`
            // itself is intentionally non-Sendable in newer SDKs.
            let keyCode = event.keyCode
            let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
            let consume = MainActor.assumeIsolated { [weak self] in
                self?.handleOptionZoomShortcut(keyCode: keyCode, modifierFlags: modifierFlags) ?? false
            }
            return consume ? nil : event
        }
    }

    private func handleOptionZoomShortcut(keyCode: UInt16, modifierFlags: UInt) -> Bool {
        guard let active = activeDashboardSurface(), !isEditingText(in: active.window) else { return false }
        let modifiers = NSEvent.ModifierFlags(rawValue: modifierFlags)
        let allowed: NSEvent.ModifierFlags = [.option, .shift, .numericPad]
        guard modifiers.contains(.option), modifiers.subtracting(allowed).isEmpty else { return false }
        switch keyCode {
        case UInt16(kVK_ANSI_Equal), UInt16(kVK_ANSI_KeypadPlus):
            adjustZoom(.increase)
            return true
        case UInt16(kVK_ANSI_Minus), UInt16(kVK_ANSI_KeypadMinus):
            adjustZoom(.decrease)
            return true
        default:
            return false
        }
    }

    private func isEditingText(in window: NSWindow) -> Bool {
        var responder = window.firstResponder
        while let current = responder {
            if current is NSTextView || current is NSTextField { return true }
            responder = current.nextResponder
        }
        return false
    }

    func hotkeyFired() { toggleBoardWindow() }

    @objc func checkForUpdates() {
        updateManager.checkForUpdates()
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
            // Clear any stale image + reset position, or a prior success's
            // `.imageOnly` would suppress the text fallback and show nothing.
            statusItem.button?.image = nil
            statusItem.button?.imagePosition = .noImage
            statusItem.button?.title = "Dash"   // keep the text fallback if rendering failed
        }
        // The rasterized image carries no SwiftUI a11y labels — describe the
        // button itself for VoiceOver + hover.
        let summary = statusSummary()
        statusItem.button?.toolTip = summary + "\nClick: dashboard · Right-click: menu"
        statusItem.button?.setAccessibilityLabel(summary)
    }

    private func statusSummary() -> String {
        if model.accounts.isEmpty { return "Claude Dash — no accounts" }
        let parts = model.accounts.prefix(4).map { a -> String in
            switch model.usage[a.id] {
            case .ok(let u): return "\(a.displayName) \(Int(u.session?.utilization ?? 0))%"
            case .stale(let u, let problem):
                return "\(a.displayName) \(Int(u.session?.utilization ?? 0))% — \(problem.needsSignIn ? "sign-in needed" : "retrying")"
            case .problem(let problem):
                return "\(a.displayName) \(problem.needsSignIn ? "sign-in needed" : "retrying")"
            default: return "\(a.displayName) —"
            }
        }
        return "Claude Dash — " + parts.joined(separator: ", ")
            + (model.anyAttention ? " · needs attention" : "")
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

    // MARK: Destructive remove (confirmed)

    /// Session key + hand-typed note are unrecoverable, so confirm first.
    func confirmRemove(_ account: Account) {
        // Bring the app forward so the sheet-style alert is visible even from
        // the menu-bar popover.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove “\(account.displayName)”?"
        alert.informativeText = "This deletes its stored session key and any note you've written for it. This can't be undone."
        alert.addButton(withTitle: "Remove")   // .alertFirstButtonReturn
        alert.addButton(withTitle: "Cancel")
        if let destructive = alert.buttons.first { destructive.hasDestructiveAction = true }
        let confirmed = alert.runModal() == .alertFirstButtonReturn
        // Restore accessory policy if no real window is keeping us .regular.
        if auxWindows.isEmpty && boardWindow == nil { NSApp.setActivationPolicy(.accessory) }
        guard confirmed else { return }
        // Defer off this button's call stack — the Remove button may live inside
        // the very Edit window we're about to close.
        DispatchQueue.main.async { [weak self] in
            self?.auxWindows["edit-\(account.id)"]?.close()
            self?.model.removeAccount(account)
        }
    }

    // MARK: Aux windows (add / edit / settings)

    private func showAddAccount() {
        presentAuxWindow(identity: "add", title: "Add Account") { done in
            AnyView(AddAccountView(model: model, onDone: done))
        }
    }

    private func showEdit(_ account: Account) {
        // Identity keyed by account so Edit on B doesn't refocus A's editor.
        presentAuxWindow(identity: "edit-\(account.id)", title: "Edit Account") { [weak self] done in
            AnyView(EditAccountView(model: self?.model ?? AppModel(), account: account,
                                    onDone: done,
                                    onRemove: { acct in self?.confirmRemove(acct) }))
        }
    }

    private func showPreferences() {
        presentAuxWindow(identity: "settings", title: "Settings") { _ in
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

    private func presentAuxWindow(identity: String, title: String,
                                  _ make: (@escaping () -> Void) -> AnyView) {
        // Single instance per identity: focus the existing window instead of
        // stacking duplicates with divergent state snapshots.
        if let existing = auxWindows[identity] {
            NSApp.setActivationPolicy(.regular)
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
        ) { [weak self] _ in
            if let token { NotificationCenter.default.removeObserver(token) }
            token = nil
            MainActor.assumeIsolated {
                guard let self else { return }
                self.auxWindows[identity] = nil
                // The board window keeps the app .regular — only demote when
                // NOTHING window-like remains.
                if self.auxWindows.isEmpty && self.boardWindow == nil {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
        auxWindows[identity] = win
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
