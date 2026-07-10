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
    /// v1.5.x had one shared Codex card and stored its note under this key.
    /// Keep it solely to migrate the note when the first identity-keyed Codex
    /// account is captured; never use it for a new account.
    static let legacyCodexKey = "codex"

    var v: Int = 1
    var global: String = ""
    var accounts: [String: AccountNote] = [:]   // Claude ids + identity-keyed Codex notes

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = (try? c.decodeIfPresent(Int.self, forKey: .v)) ?? 1
        global = (try? c.decodeIfPresent(String.self, forKey: .global)) ?? ""
        accounts = (try? c.decodeIfPresent([String: AccountNote].self, forKey: .accounts)) ?? [:]
    }

    /// Notes deliberately key off Claude Dash's local, hashed Codex account id
    /// rather than an email. One email can own both a personal and a Team plan.
    static func codexKey(for accountID: String) -> String { "codex:\(accountID)" }

    /// One-time migration for the old singleton Codex card. Never overwrite a
    /// newer per-account note; retaining the legacy note is safer than data loss.
    @discardableResult
    mutating func migrateLegacyCodexNote(to accountID: String) -> Bool {
        let destination = Self.codexKey(for: accountID)
        guard accounts[destination] == nil, let legacy = accounts[Self.legacyCodexKey] else { return false }
        accounts[destination] = legacy
        accounts[Self.legacyCodexKey] = nil
        return true
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
