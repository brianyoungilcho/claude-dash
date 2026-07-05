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

    init(text: String = "", flagged: Bool = false, updatedAt: Date = .distantPast) {
        self.text = text; self.flagged = flagged; self.updatedAt = updatedAt
    }

    // Tolerant decoding: missing keys (older/newer schema) never fail the file.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
        flagged = (try? c.decodeIfPresent(Bool.self, forKey: .flagged)) ?? false
        updatedAt = (try? c.decodeIfPresent(Date.self, forKey: .updatedAt)) ?? .distantPast
    }
}

struct NotesData: Codable, Equatable {
    var v: Int = 1
    var global: String = ""
    var accounts: [String: AccountNote] = [:]   // by account id

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = (try? c.decodeIfPresent(Int.self, forKey: .v)) ?? 1
        global = (try? c.decodeIfPresent(String.self, forKey: .global)) ?? ""
        accounts = (try? c.decodeIfPresent([String: AccountNote].self, forKey: .accounts)) ?? [:]
    }
}

enum NotesStore {
    static var fileURL: URL { AppSupport.dir.appendingPathComponent("notes.json") }

    /// Missing file = fresh start. A file that EXISTS but won't decode is user
    /// data we must not clobber: quarantine it aside so the next save can't
    /// atomically overwrite the only copy.
    static func load(from url: URL? = nil) -> NotesData {
        let url = url ?? fileURL
        guard let data = try? Data(contentsOf: url) else { return NotesData() }
        if let decoded = try? JSONDecoder().decode(NotesData.self, from: data) {
            return decoded
        }
        let quarantine = url.deletingLastPathComponent()
            .appendingPathComponent("notes.json.corrupt-\(Int(Date().timeIntervalSince1970))")
        try? FileManager.default.moveItem(at: url, to: quarantine)
        return NotesData()
    }

    static func save(_ notes: NotesData, to url: URL? = nil) {
        guard let data = try? JSONEncoder().encode(notes) else { return }
        try? data.write(to: url ?? fileURL, options: .atomic)
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
    /// updated note text unchanged except for that one marker. Only a marker at
    /// the START of the line (after whitespace) counts — a literal "- [ ]"
    /// inside the task text must never be flipped.
    static func toggle(_ note: String, line index: Int) -> String {
        var parts = note.components(separatedBy: "\n")
        guard parts.indices.contains(index) else { return note }
        let line = parts[index]
        func leadingRange(of marker: String) -> Range<String.Index>? {
            guard let r = line.range(of: marker),
                  line[line.startIndex..<r.lowerBound].allSatisfy(\.isWhitespace) else { return nil }
            return r
        }
        if let r = leadingRange(of: "- [ ] ") {
            parts[index] = line.replacingCharacters(in: r, with: "- [x] ")
        } else if let r = leadingRange(of: "- [x] ") ?? leadingRange(of: "- [X] ") {
            parts[index] = line.replacingCharacters(in: r, with: "- [ ] ")
        }
        return parts.joined(separator: "\n")
    }
}
