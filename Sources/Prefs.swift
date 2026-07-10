import Foundation

/// The discrete dashboard zoom levels. Keeping the steps central makes menu
/// actions, Preferences, and persisted values agree, while avoiding arbitrary
/// values that can produce unusable card geometry.
enum DashboardZoom {
    static let levels: [Double] = [0.9, 1.0, 1.1, 1.25, 1.4, 1.6]
    static let quickGlanceDefault = 1.0
    static let boardDefault = 1.25

    enum Direction { case increase, decrease, reset }

    /// Coerce stale/hand-edited defaults to the closest supported step. A
    /// previous release offered 150%; ties intentionally prefer the larger
    /// value, so that setting becomes the nearby 160% option rather than an
    /// unexpected reduction.
    static func normalized(_ value: Double, default defaultValue: Double) -> Double {
        guard value.isFinite, value > 0 else { return defaultValue }
        return levels.min { lhs, rhs in
            let left = abs(lhs - value), right = abs(rhs - value)
            return left == right ? lhs > rhs : left < right
        } ?? defaultValue
    }

    static func adjusted(_ value: Double, direction: Direction, default defaultValue: Double) -> Double {
        let current = normalized(value, default: defaultValue)
        switch direction {
        case .reset:
            return defaultValue
        case .increase:
            guard let index = levels.firstIndex(of: current) else { return defaultValue }
            return levels[min(index + 1, levels.count - 1)]
        case .decrease:
            guard let index = levels.firstIndex(of: current) else { return defaultValue }
            return levels[max(index - 1, 0)]
        }
    }

    static func label(_ value: Double, default defaultValue: Double) -> String {
        "\(Int((normalized(value, default: defaultValue) * 100).rounded()))%"
    }
}

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

    /// Show identity-keyed Codex usage cards (reads ~/.codex locally; no
    /// network and no persisted credentials). Defaults on — it stays invisible
    /// unless a Codex login or session data is present.
    static var monitorCodex: Bool {
        get { d.object(forKey: "monitorCodex") == nil ? true : d.bool(forKey: "monitorCodex") }
        set { d.set(newValue, forKey: "monitorCodex") }
    }

    /// Global hotkey (⌃⌥⌘D) toggles the board window.
    static var hotkeyEnabled: Bool {
        get { d.object(forKey: "hotkeyEnabled") == nil ? true : d.bool(forKey: "hotkeyEnabled") }
        set { d.set(newValue, forKey: "hotkeyEnabled") }
    }

    /// Percentage label respecting the used/remaining preference.
    static func pctLabel(_ utilization: Double) -> String {
        showRemaining ? "\(Int((100 - utilization).rounded()))% left" : "\(Int(utilization))%"
    }

    // MARK: Board & signals

    /// Board window was open at last quit → reopen at launch.
    /// (Migrates the retired v1.3 "pinned panel" state on first read.)
    static var boardWasOpen: Bool {
        get {
            if d.object(forKey: "boardPinned") != nil {   // one-time v1.3 migration
                let pinned = d.bool(forKey: "boardPinned")
                d.removeObject(forKey: "boardPinned")
                d.set(pinned, forKey: "boardWasOpen")
            }
            return d.bool(forKey: "boardWasOpen")
        }
        set { d.set(newValue, forKey: "boardWasOpen") }
    }

    /// Board window floats above other windows.
    static var boardFloats: Bool {
        get { d.object(forKey: "boardFloats") == nil ? true : d.bool(forKey: "boardFloats") }
        set { d.set(newValue, forKey: "boardFloats") }
    }

    /// Text/layout zoom for the Quick Glance popover. Kept separate from the
    /// board because the compact popover and a resizable window are used at
    /// different viewing distances.
    static var quickGlanceTextScale: Double {
        get {
            guard d.object(forKey: "quickGlanceTextScale") != nil else {
                return DashboardZoom.quickGlanceDefault
            }
            return DashboardZoom.normalized(d.double(forKey: "quickGlanceTextScale"),
                                            default: DashboardZoom.quickGlanceDefault)
        }
        set {
            d.set(DashboardZoom.normalized(newValue, default: DashboardZoom.quickGlanceDefault),
                  forKey: "quickGlanceTextScale")
        }
    }

    /// Text/layout zoom for the board window. This deliberately retains the
    /// v1.5 key so a user's existing Standard/Large/X-Large choice carries
    /// forward into the new zoom controls.
    static var boardTextScale: Double {
        get {
            guard d.object(forKey: "boardTextScale") != nil else {
                return DashboardZoom.boardDefault
            }
            return DashboardZoom.normalized(d.double(forKey: "boardTextScale"),
                                            default: DashboardZoom.boardDefault)
        }
        set {
            d.set(DashboardZoom.normalized(newValue, default: DashboardZoom.boardDefault),
                  forKey: "boardTextScale")
        }
    }

}
