import Foundation

/// Local Claude Code awareness. Two tiers:
///  - zero-config: scan ~/.claude/projects for recently-active session
///    transcripts (mtime-based "running / active Nm ago")
///  - opt-in hooks: Notification/Stop hooks append JSONL events so the board
///    can show "waiting for your input" — the real needs-attention signal.
/// Everything is local file reading; nothing leaves the machine.

struct CCSession: Equatable, Identifiable {
    var projectDisplay: String   // best-effort short name of the repo/dir
    var projectDir: String       // the encoded dir name (stable identity)
    var lastActivity: Date
    var waiting: Bool = false    // Notification hook fired, not yet resumed
    var id: String { projectDir }
}

enum ClaudeCodeMonitor {
    static var claudeDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }
    static var eventsFile: URL { AppSupport.dir.appendingPathComponent("cc-events.jsonl") }
    static var hookScript: URL { AppSupport.dir.appendingPathComponent("cc-hook.sh") }
    private static let hookMarker = "Claude Dash/cc-hook.sh"

    /// Project transcript dirs encode the path with "-" separators
    /// ("-Users-brian-Desktop-Repo"). Path components can themselves contain
    /// hyphens, so full decoding is ambiguous — the last token is the display
    /// name that's right in practice.
    static func displayName(forProjectDir dir: String) -> String {
        dir.split(separator: "-").last.map(String.init) ?? dir
    }

    /// Sessions with transcript activity in the last `window` seconds.
    static func scan(window: TimeInterval = 3600, projectsDir: URL? = nil) -> [CCSession] {
        let root = projectsDir ?? claudeDir.appendingPathComponent("projects")
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        var sessions: [CCSession] = []
        let cutoff = Date().addingTimeInterval(-window)
        for project in projects {
            guard let files = try? fm.contentsOfDirectory(at: project,
                                                          includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            let newest = files
                .filter { $0.pathExtension == "jsonl" }
                .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
                .max()
            if let newest, newest > cutoff {
                let dir = project.lastPathComponent
                sessions.append(CCSession(projectDisplay: displayName(forProjectDir: dir),
                                          projectDir: dir, lastActivity: newest))
            }
        }
        return applyEvents(to: sessions).sorted { $0.lastActivity > $1.lastActivity }
    }

    /// Overlay hook events: a session is "waiting" when its most recent event
    /// is a Notification newer than any Stop AND newer than transcript activity
    /// (transcript movement means the user already resumed it).
    static func applyEvents(to sessions: [CCSession], eventsURL: URL? = nil) -> [CCSession] {
        let url = eventsURL ?? eventsFile
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return sessions }
        // Only the tail matters; the file is rotated by the hook script.
        var latest: [String: (event: String, ts: Date)] = [:]   // by cwd
        for line in text.components(separatedBy: "\n").suffix(500) where !line.isEmpty {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let event = obj["event"] as? String,
                  let ts = (obj["ts"] as? NSNumber).map({ Date(timeIntervalSince1970: $0.doubleValue) }),
                  let payload = obj["payload"] as? [String: Any],
                  let cwd = payload["cwd"] as? String else { continue }
            if let existing = latest[cwd], existing.ts > ts { continue }
            latest[cwd] = (event, ts)
        }
        return sessions.map { s in
            var s = s
            // Match events to sessions by comparing encoded cwd to project dir.
            if let hit = latest.first(where: { encodeProjectPath($0.key) == s.projectDir })?.value {
                s.waiting = hit.event == "Notification"
                    && hit.ts > s.lastActivity.addingTimeInterval(-2)   // not superseded by resumed work
                    && hit.ts.timeIntervalSinceNow > -3600
                if hit.ts > s.lastActivity { s.lastActivity = hit.ts }
            }
            return s
        }
    }

    /// Mirror of Claude Code's path→dirname encoding ("/" and "." become "-").
    static func encodeProjectPath(_ path: String) -> String {
        path.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
    }

    // MARK: Hook install / uninstall (opt-in; merges, never clobbers)

    static var hooksInstalled: Bool {
        guard let data = try? Data(contentsOf: claudeDir.appendingPathComponent("settings.json")),
              let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains(hookMarker)
    }

    @discardableResult
    static func installHooks(settingsURL: URL? = nil) throws -> URL {
        let script = """
        #!/bin/bash
        # Claude Dash event hook — appends one JSON line per Claude Code event.
        DIR="$HOME/Library/Application Support/Claude Dash"
        FILE="$DIR/cc-events.jsonl"
        mkdir -p "$DIR"
        # rotate if large (keep the last ~500 lines)
        if [ -f "$FILE" ] && [ "$(wc -c < "$FILE")" -gt 1000000 ]; then
          tail -n 500 "$FILE" > "$FILE.tmp" && mv "$FILE.tmp" "$FILE"
        fi
        { printf '{"event":"%s","ts":%s,"payload":' "$1" "$(date +%s)"; cat -; printf '}\\n'; } >> "$FILE"
        exit 0
        """
        try script.data(using: .utf8)!.write(to: hookScript, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookScript.path)

        let url = settingsURL ?? claudeDir.appendingPathComponent("settings.json")
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = existing
        }
        // Backup before touching a file we don't own.
        if FileManager.default.fileExists(atPath: url.path) {
            let backup = url.deletingLastPathComponent()
                .appendingPathComponent("settings.json.claude-dash-backup")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: url, to: backup)
        }

        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in ["Notification", "Stop"] {
            var entries = hooks[event] as? [[String: Any]] ?? []
            let already = entries.contains { entry in
                ((entry["hooks"] as? [[String: Any]]) ?? []).contains { cmd in
                    (cmd["command"] as? String)?.contains(hookMarker) == true
                }
            }
            if !already {
                entries.append(["hooks": [[
                    "type": "command",
                    "command": "\"$HOME/Library/Application Support/Claude Dash/cc-hook.sh\" \(event)"
                ]]])
                hooks[event] = entries
            }
        }
        settings["hooks"] = hooks
        let out = try JSONSerialization.data(withJSONObject: settings,
                                             options: [.prettyPrinted, .sortedKeys])
        try out.write(to: url, options: .atomic)
        return url
    }

    static func uninstallHooks(settingsURL: URL? = nil) throws {
        let url = settingsURL ?? claudeDir.appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: url),
              var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = settings["hooks"] as? [String: Any] else { return }
        for (event, value) in hooks {
            guard var entries = value as? [[String: Any]] else { continue }
            entries.removeAll { entry in
                ((entry["hooks"] as? [[String: Any]]) ?? []).contains { cmd in
                    (cmd["command"] as? String)?.contains(hookMarker) == true
                }
            }
            hooks[event] = entries.isEmpty ? nil : entries
        }
        settings["hooks"] = hooks
        let out = try JSONSerialization.data(withJSONObject: settings,
                                             options: [.prettyPrinted, .sortedKeys])
        try out.write(to: url, options: .atomic)
        try? FileManager.default.removeItem(at: hookScript)
    }
}
