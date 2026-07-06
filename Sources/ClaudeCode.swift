import Foundation

/// Local Claude Code awareness — hooks-only by design. The section appears
/// ONLY after the user opts into hooks (Preferences → Install): Notification /
/// Stop events carry the real signal ("waiting for your input"), and the cwd
/// in each event is a plain path — no directory-name guessing. Everything is
/// local file reading; nothing leaves the machine.

struct CCSession: Equatable, Identifiable {
    var projectDisplay: String   // last path component of the session's cwd
    var projectDir: String       // the full cwd (stable identity)
    var lastActivity: Date
    var waiting: Bool = false    // most recent event is a Notification
    var id: String { projectDir }
}

enum ClaudeCodeMonitor {
    static var claudeDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }
    static var eventsFile: URL { AppSupport.dir.appendingPathComponent("cc-events.jsonl") }
    static var hookScript: URL { AppSupport.dir.appendingPathComponent("cc-hook.sh") }
    private static let hookMarker = "Claude Dash/cc-hook.sh"

    /// The current Claude Code login's organization, from ~/.claude.json
    /// (metadata only — credentials live elsewhere). Lets the board attach
    /// sessions to the exact account whose org the CLI is burning usage from.
    static func currentLoginOrgUuid(configURL: URL? = nil) -> String? {
        let url = configURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = obj["oauthAccount"] as? [String: Any] else { return nil }
        return account["organizationUuid"] as? String
    }

    /// Sessions reconstructed purely from hook events within `window` seconds.
    /// No hooks (or no recent events) → empty → the UI section disappears.
    static func sessionsFromEvents(eventsURL: URL? = nil, window: TimeInterval = 3600,
                                   now: Date = Date()) -> [CCSession] {
        let url = eventsURL ?? eventsFile
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
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
        let cutoff = now.addingTimeInterval(-window)
        return latest.compactMap { cwd, hit in
            guard hit.ts > cutoff else { return nil }
            return CCSession(projectDisplay: URL(fileURLWithPath: cwd).lastPathComponent,
                             projectDir: cwd,
                             lastActivity: hit.ts,
                             waiting: hit.event == "Notification")
        }
        .sorted { $0.lastActivity > $1.lastActivity }
    }

    // MARK: Hook install / uninstall (opt-in; merges, never clobbers)

    /// Parsed check — raw-text contains() would be defeated by
    /// JSONSerialization's "\/" slash escaping in the file WE write.
    static func hooksInstalled(settingsURL: URL? = nil) -> Bool {
        let url = settingsURL ?? claudeDir.appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = obj["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { value in
            ((value as? [[String: Any]]) ?? []).contains(where: entryHasMarker)
        }
    }

    private static func entryHasMarker(_ entry: [String: Any]) -> Bool {
        ((entry["hooks"] as? [[String: Any]]) ?? []).contains { cmd in
            (cmd["command"] as? String)?.contains(hookMarker) == true
        }
    }

    @discardableResult
    static func installHooks(settingsURL: URL? = nil) throws -> URL {
        // Claude Code writes the hook payload as JSON + a trailing newline;
        // capture via $(…) (which strips trailing newlines) so the composed
        // record stays on ONE line, and emit it with a single printf so
        // concurrent hooks can't interleave partial writes.
        let script = """
        #!/bin/bash
        # Claude Dash event hook — appends one JSON line per Claude Code event.
        # CLAUDE_DASH_DIR override exists so the test suite never touches the
        # real events file (it did once; a phantom "test dir" session haunted
        # the board for an hour).
        DIR="${CLAUDE_DASH_DIR:-$HOME/Library/Application Support/Claude Dash}"
        FILE="$DIR/cc-events.jsonl"
        mkdir -p "$DIR"
        # rotate if large (keep the last ~500 lines)
        if [ -f "$FILE" ] && [ "$(wc -c < "$FILE")" -gt 1000000 ]; then
          tail -n 500 "$FILE" > "$FILE.tmp" && mv "$FILE.tmp" "$FILE"
        fi
        payload=$(cat -)
        [ -z "$payload" ] && payload='{}'
        printf '{"event":"%s","ts":%s,"payload":%s}\\n' "$1" "$(date +%s)" "$payload" >> "$FILE"
        exit 0
        """
        try script.data(using: .utf8)!.write(to: hookScript, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookScript.path)

        let url = settingsURL ?? claudeDir.appendingPathComponent("settings.json")
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: url) {
            // The file exists: refusing to parse it must ABORT, not proceed
            // with empty settings — that would wipe the user's live config.
            guard let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NSError(domain: "ClaudeDash", code: 1, userInfo: [
                    NSLocalizedDescriptionKey:
                        "~/.claude/settings.json exists but isn't valid JSON. Nothing was changed — fix the file first."])
            }
            settings = existing
            // Keep the FIRST (pristine) backup; never overwrite it with a
            // hooked version on a second Install click.
            let backup = url.deletingLastPathComponent()
                .appendingPathComponent("settings.json.claude-dash-backup")
            if !FileManager.default.fileExists(atPath: backup.path) {
                try? FileManager.default.copyItem(at: url, to: backup)
            }
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
