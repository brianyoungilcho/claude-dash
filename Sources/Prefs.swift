import Foundation

/// Typed access to user preferences. All values have sensible defaults so a
/// fresh install needs no configuration.
enum Prefs {
    private static var d: UserDefaults { .standard }

    /// Seconds between usage polls.
    static var pollInterval: TimeInterval {
        get { let v = d.double(forKey: "pollInterval"); return v >= 30 ? v : 60 }
        set { d.set(newValue, forKey: "pollInterval") }
    }

    /// Session-usage % that triggers a notification. 0 = notifications off.
    static var notifyThreshold: Int {
        get { d.object(forKey: "notifyThreshold") == nil ? 90 : d.integer(forKey: "notifyThreshold") }
        set { d.set(newValue, forKey: "notifyThreshold") }
    }

    /// Notify when a capped account's session window resets.
    static var notifyOnReset: Bool {
        get { d.object(forKey: "notifyOnReset") == nil ? true : d.bool(forKey: "notifyOnReset") }
        set { d.set(newValue, forKey: "notifyOnReset") }
    }

    /// Show "% left" instead of "% used" on metric labels.
    static var showRemaining: Bool {
        get { d.bool(forKey: "showRemaining") }
        set { d.set(newValue, forKey: "showRemaining") }
    }

    enum SortMode: String, CaseIterable {
        case manual        // config order
        case headroom      // most session headroom first
        case used          // most session usage first
        var label: String {
            switch self {
            case .manual: return "Added order"
            case .headroom: return "Most headroom first"
            case .used: return "Most used first"
            }
        }
    }
    static var sortMode: SortMode {
        get { SortMode(rawValue: d.string(forKey: "sortMode") ?? "") ?? .manual }
        set { d.set(newValue.rawValue, forKey: "sortMode") }
    }

    enum MenuBarMode: String, CaseIterable {
        case all           // one gauge chip per account
        case tightest      // only the account closest to its session cap
        case icon          // just the gauge glyph
        var label: String {
            switch self {
            case .all: return "All accounts"
            case .tightest: return "Tightest account only"
            case .icon: return "Icon only"
            }
        }
    }
    static var menuBarMode: MenuBarMode {
        get { MenuBarMode(rawValue: d.string(forKey: "menuBarMode") ?? "") ?? .all }
        set { d.set(newValue.rawValue, forKey: "menuBarMode") }
    }

    /// Global hotkey (⌃⌥⌘D) toggles the dashboard.
    static var hotkeyEnabled: Bool {
        get { d.object(forKey: "hotkeyEnabled") == nil ? true : d.bool(forKey: "hotkeyEnabled") }
        set { d.set(newValue, forKey: "hotkeyEnabled") }
    }

    /// Percentage label respecting the used/remaining preference.
    static func pctLabel(_ utilization: Double) -> String {
        showRemaining ? "\(Int((100 - utilization).rounded()))% left" : "\(Int(utilization))%"
    }

    // MARK: Board & signals

    /// Board pinned open (persisted so it reopens the way you left it).
    static var boardPinned: Bool {
        get { d.bool(forKey: "boardPinned") }
        set { d.set(newValue, forKey: "boardPinned") }
    }

    /// Pinned board floats above other windows.
    static var boardFloats: Bool {
        get { d.object(forKey: "boardFloats") == nil ? true : d.bool(forKey: "boardFloats") }
        set { d.set(newValue, forKey: "boardFloats") }
    }

    /// Show recent claude.ai conversations under each account.
    static var showConversations: Bool {
        get { d.object(forKey: "showConversations") == nil ? true : d.bool(forKey: "showConversations") }
        set { d.set(newValue, forKey: "showConversations") }
    }

    /// Show local Claude Code session activity on the board.
    static var ccMonitor: Bool {
        get { d.object(forKey: "ccMonitor") == nil ? true : d.bool(forKey: "ccMonitor") }
        set { d.set(newValue, forKey: "ccMonitor") }
    }
}
