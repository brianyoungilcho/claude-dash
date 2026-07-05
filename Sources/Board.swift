import SwiftUI

/// The board window: a real, resizable macOS window where accounts become
/// cards in an adaptive grid, rendered at the user's preferred text scale.
/// `BoardContent` is pure props so the preview harness can render it without
/// an AppModel.

struct BoardContent: View {
    var accounts: [Account]
    var usage: [String: UsageState]
    var notes: NotesData
    var convos: [String: [Convo]]
    var ccSessions: [CCSession]
    var lastRefresh: Date?

    var onAdd: () -> Void = {}
    var onEdit: (Account) -> Void = { _ in }
    var onPrefs: () -> Void = {}
    var onRefresh: () -> Void = {}
    var open: (Account, String) -> Void = { _, _ in }
    var toggleFlag: (Account) -> Void = { _ in }
    var remove: (Account) -> Void = { _ in }
    var noteChanged: (Account, String) -> Void = { _, _ in }
    var globalNoteChanged: (String) -> Void = { _ in }
    var noteCommitted: () -> Void = {}
    /// Preview harness renders the inner content directly — ScrollView+LazyVGrid
    /// produce nothing under a headless ImageRenderer.
    var embedInScrollView = true

    @Environment(\.dashScale) private var s

    private var cardColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 340 * s, maximum: 560 * s), spacing: 12, alignment: .top)]
    }

    var body: some View {
        Group {
            if embedInScrollView {
                ScrollView { inner }
            } else {
                inner
            }
        }
        .frame(minWidth: 380 * s, minHeight: 320)
    }

    private var inner: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            NoteView(text: notes.global,
                     placeholder: "Scratchpad — what's going on across everything…",
                     onChange: globalNoteChanged,
                     onCommit: noteCommitted)
            LazyVGrid(columns: cardColumns, alignment: .leading, spacing: 12) {
                ForEach(accounts) { account in
                    card {
                        AccountRow(
                            account: account,
                            state: usage[account.id] ?? .unknown,
                            noteText: notes.accounts[account.id]?.text ?? "",
                            flagged: notes.accounts[account.id]?.flagged == true,
                            convos: Prefs.showConversations ? (convos[account.id] ?? []) : [],
                            open: { open(account, "/new") },
                            openUsage: { open(account, "/settings/usage") },
                            openConvo: { open(account, "/chat/\($0.uuid)") },
                            edit: { onEdit(account) },
                            remove: { remove(account) },
                            toggleFlag: { toggleFlag(account) },
                            noteChanged: { noteChanged(account, $0) },
                            noteCommitted: noteCommitted
                        )
                    }
                }
                if !ccSessions.isEmpty {
                    card { ClaudeCodeSection(sessions: ccSessions) }
                }
            }
        }
        .padding(16)
    }

    private func card<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
    }

    private var header: some View {
        HStack {
            Button("Add account…", action: onAdd).controlSize(.regular)
            Spacer()
            if let d = lastRefresh {
                Text("Updated \(d.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 10 * s)).foregroundStyle(.secondary)
            }
            Button(action: onPrefs) { Image(systemName: "gearshape") }
                .buttonStyle(.borderless).help("Preferences")
            Button(action: onRefresh) { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Refresh all")
        }
    }
}

struct BoardView: View {
    @ObservedObject var model: AppModel
    var onAdd: () -> Void
    var onEdit: (Account) -> Void
    var onPrefs: () -> Void

    var body: some View {
        BoardContent(
            accounts: model.sortedAccounts,
            usage: model.usage,
            notes: model.notes,
            convos: model.convos,
            ccSessions: model.ccSessions,
            lastRefresh: model.lastRefresh,
            onAdd: onAdd,
            onEdit: onEdit,
            onPrefs: onPrefs,
            onRefresh: { Task { await model.userRefresh() } },
            open: { model.openChrome($0, path: $1) },
            toggleFlag: { model.toggleFlag(accountId: $0.id) },
            remove: { model.removeAccount($0) },
            noteChanged: { model.setNote(accountId: $0.id, text: $1) },
            globalNoteChanged: { model.setGlobalNote($0) },
            noteCommitted: { model.flushNotesNow() }
        )
        .environment(\.dashScale, CGFloat(Prefs.boardTextScale))
    }
}
