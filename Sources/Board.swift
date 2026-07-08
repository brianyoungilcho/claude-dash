import SwiftUI

/// The board window: a real, resizable macOS window where accounts become
/// cards in an adaptive grid, rendered at the user's preferred text scale.
/// `BoardContent` is pure props so the preview harness can render it without
/// an AppModel.

struct BoardContent: View {
    var accounts: [Account]
    var usage: [String: UsageState]
    var notes: NotesData
    var ccSessions: [CCSession]          // unmatched-only (standalone card)
    var ccByAccount: [String: [CCSession]] = [:]   // owner account id → sessions
    var codex: CodexUsage? = nil         // local Codex usage card (nil = hidden)
    var lastRefresh: Date?
    var displayTick: Int = 0
    var isRefreshing = false

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
    var moveUp: (Account) -> (() -> Void)? = { _ in nil }
    var moveDown: (Account) -> (() -> Void)? = { _ in nil }
    /// Preview harness renders the inner content directly — ScrollView+LazyVGrid
    /// produce nothing under a headless ImageRenderer.
    var embedInScrollView = true

    @Environment(\.dashScale) private var s

    private var cardColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 340 * s, maximum: 560 * s), spacing: 12, alignment: .top)]
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            if accounts.isEmpty && codex == nil && ccSessions.isEmpty {
                EmptyAccountsView(onAdd: onAdd)
                    .frame(maxHeight: .infinity)
            } else if embedInScrollView {
                ScrollView { grid }.endEditingOnBackgroundTap()
            } else {
                grid
            }
        }
        .frame(minWidth: 400, minHeight: 320)
    }

    private var grid: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                            ccSessions: ccByAccount[account.id] ?? [],
                            open: { open(account, "/new") },
                            openUsage: { open(account, "/settings/usage") },
                            edit: { onEdit(account) },
                            remove: { remove(account) },
                            toggleFlag: { toggleFlag(account) },
                            noteChanged: { noteChanged(account, $0) },
                            noteCommitted: noteCommitted,
                            moveUp: moveUp(account),
                            moveDown: moveDown(account)
                        )
                    }
                }
                if let codex {
                    card { CodexSection(usage: codex, tick: displayTick) }
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
            UpdatedFooterText(lastRefresh: lastRefresh, tick: displayTick)
            Button(action: onPrefs) { Image(systemName: "gearshape") }
                .buttonStyle(.borderless).help("Settings")
            if isRefreshing {
                ProgressView().controlSize(.small).frame(width: 20)
            } else {
                Button(action: onRefresh) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh all").frame(width: 20)
            }
        }
    }
}

struct BoardView: View {
    @ObservedObject var model: AppModel
    var onAdd: () -> Void
    var onEdit: (Account) -> Void
    var onPrefs: () -> Void
    var onRemove: (Account) -> Void = { _ in }

    var body: some View {
        BoardContent(
            accounts: model.sortedAccounts,
            usage: model.usage,
            notes: model.notes,
            ccSessions: model.ccUnmatchedSessions,
            ccByAccount: model.ccOwnerAccountId.map { [$0: model.ccSessions] } ?? [:],
            codex: model.codex,
            lastRefresh: model.lastRefresh,
            displayTick: model.displayTick,
            isRefreshing: model.isRefreshing,
            onAdd: onAdd,
            onEdit: onEdit,
            onPrefs: onPrefs,
            onRefresh: { Task { await model.userRefresh() } },
            open: { model.openChrome($0, path: $1) },
            toggleFlag: { model.toggleFlag(accountId: $0.id) },
            remove: onRemove,
            noteChanged: { model.setNote(accountId: $0.id, text: $1) },
            globalNoteChanged: { model.setGlobalNote($0) },
            noteCommitted: { model.flushNotesNow() },
            moveUp: { a in moveClosure(a, in: model.sortedAccounts, by: -1, model: model) },
            moveDown: { a in moveClosure(a, in: model.sortedAccounts, by: 1, model: model) }
        )
        .environment(\.dashScale, CGFloat(Prefs.boardTextScale))
    }
}
