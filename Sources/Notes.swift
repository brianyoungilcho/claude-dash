import Foundation

// MARK: - App support directory

enum AppSupport {
    static var dir: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Claude Dash", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

// MARK: - Notes model (local JSON file; never synced, never sent anywhere)

struct AccountNote: Codable, Equatable {
    var text: String = ""
    var flagged: Bool = false
    var updatedAt: Date = .distantPast
}

struct NotesData: Codable, Equatable {
    var v: Int = 1
    var global: String = ""
    var accounts: [String: AccountNote] = [:]   // by account id
}

enum NotesStore {
    static var fileURL: URL { AppSupport.dir.appendingPathComponent("notes.json") }

    static func load() -> NotesData {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(NotesData.self, from: data) else {
            return NotesData()
        }
        return decoded
    }

    static func save(_ notes: NotesData) {
        guard let data = try? JSONEncoder().encode(notes) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - Checkbox lines ("- [ ] task" / "- [x] done") — pure + testable

enum NoteLine: Equatable {
    case checkbox(done: Bool, text: String)
    case plain(String)
}

enum NoteParser {
    /// Split a note into renderable lines, detecting checkbox syntax.
    static func lines(_ note: String) -> [NoteLine] {
        note.components(separatedBy: "\n").map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- [ ] ") {
                return .checkbox(done: false, text: String(trimmed.dropFirst(6)))
            }
            if trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ") {
                return .checkbox(done: true, text: String(trimmed.dropFirst(6)))
            }
            return .plain(line)
        }
    }

    /// Toggle the checkbox on line `index` (0-based over ALL lines); returns the
    /// updated note text unchanged except for that one marker.
    static func toggle(_ note: String, line index: Int) -> String {
        var parts = note.components(separatedBy: "\n")
        guard parts.indices.contains(index) else { return note }
        let line = parts[index]
        if let r = line.range(of: "- [ ] ") {
            parts[index] = line.replacingCharacters(in: r, with: "- [x] ")
        } else if let r = line.range(of: "- [x] ") {
            parts[index] = line.replacingCharacters(in: r, with: "- [ ] ")
        } else if let r = line.range(of: "- [X] ") {
            parts[index] = line.replacingCharacters(in: r, with: "- [ ] ")
        }
        return parts.joined(separator: "\n")
    }
}
