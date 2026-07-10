import SwiftUI
import AppKit

// MARK: - Density scale (popover = 1.0; board window = user preference)

private struct DashScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1.0 }
extension EnvironmentValues {
    var dashScale: CGFloat {
        get { self[DashScaleKey.self] }
        set { self[DashScaleKey.self] = newValue }
    }
}

// MARK: - Shared helpers

func usageColor(_ pct: Double) -> Color {
    pct >= 90 ? .red : pct >= 75 ? .orange : .green
}

/// Container-surface opacity that steps up under Increase Contrast.
func surfaceOpacity(_ base: Double, _ contrast: ColorSchemeContrast) -> Double {
    contrast == .increased ? min(base * 2.4, 0.22) : base
}

/// Move Up/Down action for a card. Reorders relative to the VISIBLE order and
/// only within the same flag group — flagged accounts are pinned on top, so a
/// cross-boundary move would be a confusing no-op. Returns nil when not shown.
@MainActor
func moveClosure(_ a: Account, in visible: [Account], by offset: Int,
                 model: AppModel) -> (() -> Void)? {
    guard Prefs.sortMode == .manual,
          let vIdx = visible.firstIndex(where: { $0.id == a.id }) else { return nil }
    let target = vIdx + offset
    guard visible.indices.contains(target),
          model.isFlagged(a.id) == model.isFlagged(visible[target].id) else { return nil }
    let otherId = visible[target].id
    return { model.swapAccounts(a.id, otherId) }
}

/// A subtle hover wash + pointing cursor for otherwise-unstyled click targets.
struct HoverHighlight: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 4)
                .fill(Color.primary.opacity(hovering ? 0.06 : 0)))
            .onHover { h in
                hovering = h
                if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }
}

/// De-emphasize a card whose account is at a 100% limit so attention flows to
/// the accounts that still have headroom. Kept legible (controls stay
/// clickable), and dimmed less under Increase Contrast.
struct CappedDim: ViewModifier {
    var capped: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        content.opacity(capped ? (contrast == .increased ? 0.8 : 0.6) : 1)
    }
}

extension View {
    func hoverHighlight() -> some View { modifier(HoverHighlight()) }

    func cappedDim(_ capped: Bool) -> some View { modifier(CappedDim(capped: capped)) }

    /// Clicks in empty window space end any in-progress note edit (macOS only
    /// moves keyboard focus on control clicks, so we resign first responder
    /// explicitly). The TextEditor's focus-loss handler then commits the note.
    func endEditingOnBackgroundTap() -> some View {
        background(
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { NSApp.keyWindow?.makeFirstResponder(nil) }
        )
    }
}

func resetString(_ date: Date?) -> String {
    guard let date else { return "" }
    let secs = date.timeIntervalSinceNow
    if secs <= 0 { return "resetting…" }
    let totalMinutes = Int(secs) / 60
    let d = totalMinutes / 1440, h = (totalMinutes % 1440) / 60, m = totalMinutes % 60
    if d > 0 { return "resets in \(d)d \(h)h" }
    if h > 0 { return "resets in \(h)h \(m)m" }
    return "resets in \(m)m"
}

// MARK: - Usage bar

struct UsageBar: View {
    var pct: Double
    var height: CGFloat = 7
    @Environment(\.dashScale) private var s
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height * s / 2)
                    .fill(Color.primary.opacity(surfaceOpacity(0.12, contrast)))
                RoundedRectangle(cornerRadius: height * s / 2)
                    .fill(usageColor(pct))
                    .frame(width: max(0, min(1, pct / 100)) * geo.size.width)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: pct)
            }
        }
        .frame(height: height * s)
        .accessibilityElement()
        .accessibilityLabel("\(Int(pct)) percent used")
    }
}

/// One compact metric row: fixed-width label, small bar, percent, trailing text.
struct MetricLine: View {
    var label: String
    var metric: UsageMetric
    var trailing: String? = nil   // defaults to the reset countdown
    @Environment(\.dashScale) private var s

    var body: some View {
        HStack(spacing: 6 * s) {
            Text(label)
                .font(.system(size: 9 * s, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: 44 * s, alignment: .leading)
                .lineLimit(1)
            UsageBar(pct: metric.utilization, height: 4)
            Text(Prefs.pctLabel(metric.utilization))
                .font(.system(size: 9 * s, weight: .medium)).monospacedDigit()
                .foregroundStyle(usageColor(metric.utilization))
                .frame(minWidth: 30 * s, alignment: .trailing)
            Text(trailing ?? resetString(metric.resetsAt))
                .font(.system(size: 8 * s)).foregroundStyle(.secondary)
                .frame(width: 76 * s, alignment: .trailing)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(Prefs.pctLabel(metric.utilization)), \(trailing ?? resetString(metric.resetsAt))")
    }
}

// MARK: - Note (display mode renders checkboxes; click to edit)

struct NoteView: View {
    var text: String
    var placeholder: String
    var onChange: (String) -> Void
    var onCommit: () -> Void = {}   // fired when an edit session ends → flush to disk

    @Environment(\.dashScale) private var s
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.controlActiveState) private var activeState
    @State private var editing = false
    // Edit-session buffer: the editor binds this stable local state, so model
    // republishes (polls, ticks, the per-keystroke echo through @Published
    // notes) can never rewrite the NSTextView mid-edit — that rewrite is what
    // threw the caret to the end and broke Korean IME composition.
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                VStack(alignment: .leading, spacing: 4 * s) {
                    TextEditor(text: $draft)
                        .font(.system(size: 11 * s))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 52 * s, maxHeight: 160 * s)
                        .focused($focused)
                        // Stream every change so autosave, quit-flush, and the
                        // other surface (popover/board can show the same note)
                        // stay live while typing.
                        .onChange(of: draft, perform: onChange)
                        .onChange(of: focused) { if !$0 { finishEditing() } }
                        .onExitCommand { finishEditing() }   // Esc commits the note
                    HStack(spacing: 6) {
                        Text("Saves automatically · “- [ ] task” becomes a checkbox")
                            .font(.system(size: 9 * s)).foregroundStyle(.tertiary)
                            .lineLimit(1)
                        Spacer()
                        Button("Done") { finishEditing() }
                            .controlSize(.small)
                            .keyboardShortcut(.return, modifiers: .command)
                            .help("Finish editing (⌘⏎ or Esc). Notes also save when you click away.")
                    }
                }
            } else if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 10 * s)).foregroundStyle(.secondary)
                    Text(placeholder)
                        .font(.system(size: 11 * s)).foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(perform: startEditing)
                .hoverHighlight()
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(placeholder)
                .accessibilityHint("Edit note")
                .accessibilityAction(.default, startEditing)
            } else {
                VStack(alignment: .leading, spacing: 2 * s) {
                    ForEach(Array(NoteParser.lines(text).enumerated()), id: \.offset) { idx, line in
                        switch line {
                        case .checkbox(let done, let body):
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                Button {
                                    onChange(NoteParser.toggle(text, line: idx))
                                    onCommit()
                                } label: {
                                    Image(systemName: done ? "checkmark.square.fill" : "square")
                                        .font(.system(size: 11 * s))
                                        .foregroundStyle(done ? Color.accentColor : .secondary)
                                }
                                .buttonStyle(.plain)
                                .help(done ? "Mark as not done" : "Mark as done")
                                .accessibilityLabel(body)
                                .accessibilityValue(done ? "checked" : "unchecked")
                                Text(body)
                                    .font(.system(size: 11 * s))
                                    .strikethrough(done)
                                    .foregroundStyle(done ? .secondary : .primary)
                            }
                        case .plain(let body):
                            Text(body.isEmpty ? " " : body).font(.system(size: 11 * s))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(perform: startEditing)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 9 * s))
                        .foregroundStyle(contrast == .increased ? .secondary : .tertiary)
                        .accessibilityHidden(true)
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Edit note")
                .accessibilityAction(.default, startEditing)
            }
        }
        .padding(6 * s)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(surfaceOpacity(0.05, contrast))))
        .overlay {
            if editing {
                RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1.5)
            }
        }
        .help("Click to edit. Lines like “- [ ] task” become checkboxes. Saves automatically.")
        // Commit the moment this window stops being key: the popover and board
        // can both show the same note, and macOS windows keep their first
        // responder while non-key — so without this, an editor left open in the
        // other window would hold a stale draft whose next keystroke streams
        // over everything written here since.
        .onChange(of: activeState) { if $0 != .key { finishEditing() } }
    }

    private func startEditing() { draft = text; editing = true; focused = true }

    private func finishEditing() {
        guard editing else { return }   // focus-loss, Esc/Done, and window-deactivate can stack
        editing = false
        focused = false
        // No final draft push: every change already streamed via onChange, and
        // re-pushing here would let a stale editor left open in the other
        // window clobber newer text written since.
        onCommit()
    }
}

// MARK: - Dashboard panel

/// Shared "no accounts yet" guidance (popover + board window).
struct EmptyAccountsView: View {
    var onAdd: () -> Void
    @Environment(\.dashScale) private var s
    var body: some View {
        VStack(spacing: 10 * s) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.system(size: 30 * s)).foregroundStyle(.secondary)
            Text("No accounts yet").font(.system(size: 13 * s, weight: .medium))
            Text("Add a Claude account to see its usage and jump into the right browser profile.")
                .font(.system(size: 11 * s)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Add account…", action: onAdd).controlSize(.large)
        }
        .padding(24 * s)
        .frame(maxWidth: .infinity)
    }
}

/// Footer "Updated …" line, orange with a wifi-slash icon once stale.
struct UpdatedFooterText: View {
    var lastRefresh: Date?
    var tick: Int   // dependency so it recomputes on the minute pulse
    var body: some View {
        if let info = updatedLabel(lastRefresh, pollInterval: Prefs.pollInterval) {
            HStack(spacing: 3) {
                if info.stale {
                    Image(systemName: "wifi.slash").font(.system(size: 9))
                }
                Text(info.stale ? "\(info.text) — retrying" : info.text)
                    .font(.system(size: 10))
            }
            .foregroundStyle(info.stale ? Color.orange : Color.secondary)
        }
    }
}

/// A multi-account outage is materially different from a bad individual
/// credential. This stays local and user-driven: opening the status page does
/// not add background polling or send any account data.
struct UsageProblemBanner: View {
    var problem: UsageProblem
    @Environment(\.dashScale) private var s

    var body: some View {
        HStack(alignment: .top, spacing: 6 * s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11 * s)).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2 * s) {
                Text(problem.display).font(.system(size: 11 * s, weight: .medium))
                Text("Your stored sign-ins were not changed.")
                    .font(.system(size: 10 * s)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button("Status") {
                NSWorkspace.shared.open(URL(string: "https://status.claude.com/")!)
            }
            .buttonStyle(.borderless)
            .font(.system(size: 10 * s, weight: .medium))
        }
        .padding(8 * s)
        .background(RoundedRectangle(cornerRadius: 6 * s).fill(Color.orange.opacity(0.09)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Claude usage may be temporarily unavailable across accounts")
    }
}

/// Refresh button that shows a spinner and disables itself while in flight.
struct RefreshButton: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Group {
            if model.isRefreshing {
                ProgressView().controlSize(.small)
            } else {
                Button(action: { Task { await model.userRefresh() } }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh all")
            }
        }
        .frame(width: 20)
    }
}

struct DashboardView: View {
    @ObservedObject var model: AppModel
    var onAdd: () -> Void
    var onEdit: (Account) -> Void
    var onPrefs: () -> Void
    var onRemove: (Account) -> Void = { _ in }
    var onOpenBoard: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.accounts.isEmpty && model.codex == nil && model.ccUnmatchedSessions.isEmpty {
                EmptyAccountsView(onAdd: onAdd)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        if let problem = model.globalUsageProblem {
                            UsageProblemBanner(problem: problem)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                            Divider()
                        }
                        globalNote
                        Divider()
                        let visible = model.sortedAccounts
                        ForEach(visible) { account in
                            AccountRow(
                                account: account,
                                state: model.usage[account.id] ?? .unknown,
                                noteText: model.notes.accounts[account.id]?.text ?? "",
                                flagged: model.isFlagged(account.id),
                                ccSessions: model.ccSessions(for: account.id),
                                open: { model.openChrome(account, path: "/new") },
                                openUsage: { model.openChrome(account, path: "/settings/usage") },
                                edit: { onEdit(account) },
                                retry: { Task { _ = await model.refresh(account, force: true) } },
                                remove: { onRemove(account) },
                                toggleFlag: { model.toggleFlag(accountId: account.id) },
                                noteChanged: { model.setNote(accountId: account.id, text: $0) },
                                noteCommitted: { model.flushNotesNow() },
                                moveUp: moveClosure(account, in: visible, by: -1, model: model),
                                moveDown: moveClosure(account, in: visible, by: 1, model: model)
                            )
                            Divider()
                        }
                        if let codex = model.codex {
                            CodexSection(usage: codex, tick: model.displayTick,
                                         noteText: model.notes.accounts[NotesData.codexKey]?.text ?? "",
                                         noteChanged: { model.setNote(accountId: NotesData.codexKey, text: $0) },
                                         noteCommitted: { model.flushNotesNow() })
                            Divider()
                        }
                        if !model.ccUnmatchedSessions.isEmpty {
                            ClaudeCodeSection(sessions: model.ccUnmatchedSessions)
                            Divider()
                        }
                    }
                }
                .endEditingOnBackgroundTap()
            }
            footer
        }
        .frame(width: 340)
        .frame(maxHeight: 560)
    }


    private var header: some View {
        HStack {
            Text("Claude Dash").font(.system(size: 13, weight: .semibold))
            Spacer()
            Button(action: onOpenBoard) { Image(systemName: "macwindow") }
                .buttonStyle(.borderless)
                .help("Open as a window — bigger text, resizable, notes side by side (⌃⌥⌘D)")
            Button(action: onPrefs) { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .help("Settings")
            RefreshButton(model: model)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var globalNote: some View {
        NoteView(text: model.notes.global,
                 placeholder: "Scratchpad — what's going on across everything…",
                 onChange: { model.setGlobalNote($0) },
                 onCommit: { model.flushNotesNow() })
            .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Button("Add account…", action: onAdd).buttonStyle(.borderless)
                Spacer()
                UpdatedFooterText(lastRefresh: model.lastRefresh, tick: model.displayTick)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
        }
    }
}

struct AccountRow: View {
    var account: Account
    var state: UsageState
    var noteText: String = ""
    var flagged: Bool = false
    var ccSessions: [CCSession] = []   // Claude Code sessions owned by this account's org
    var open: () -> Void
    var openUsage: () -> Void
    var edit: () -> Void
    var retry: () -> Void = {}
    var remove: () -> Void
    var toggleFlag: () -> Void = {}
    var noteChanged: (String) -> Void = { _ in }
    var noteCommitted: () -> Void = {}
    var moveUp: (() -> Void)? = nil     // shown only in manual sort mode
    var moveDown: (() -> Void)? = nil
    @Environment(\.dashScale) private var s

    /// Some limit is at 100% — nothing to act on here until a reset. A manual
    /// attention flag wins over the dim: the user explicitly pinned focus here.
    private var capped: Bool {
        state.snapshot?.anyLimitCapped ?? false
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8 * s) {
            VStack(alignment: .leading, spacing: 5 * s) {
                HStack(spacing: 6 * s) {
                    if flagged {
                        Image(systemName: "flag.fill")
                            .font(.system(size: 9 * s)).foregroundStyle(.orange)
                    }
                    Text(account.displayName).font(.system(size: 12 * s, weight: .semibold))
                    Spacer()
                    statusBadge
                }
                content
                if !ccSessions.isEmpty {
                    CCSessionLines(sessions: ccSessions)
                }
                NoteView(text: noteText,
                         placeholder: "What am I working on here…",
                         onChange: noteChanged,
                         onCommit: noteCommitted)
                Text(account.chromeProfileLabel)
                    .font(.system(size: 10 * s)).foregroundStyle(.secondary).lineLimit(1)
            }
            VStack(alignment: .trailing, spacing: 5 * s) {
                Button(action: open) {
                    Text("Open").font(.system(size: 11 * s, weight: .medium))
                }
                .controlSize(.small)
                .help("Open claude.ai in \(account.chromeProfileLabel)")
                Menu {
                    rowMenuItems
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 24 * s)
                .help("More actions")
            }
        }
        .padding(.horizontal, 12 * s).padding(.vertical, 9 * s)
        .background(flagged ? Color.orange.opacity(0.06) : Color.clear)
        .overlay(alignment: .leading) {
            if flagged { Rectangle().fill(Color.orange).frame(width: 2) }
        }
        .cappedDim(capped && !flagged)
        .contextMenu { rowMenuItems }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Account \(account.displayName), \(healthDescription)\(flagged ? ", flagged for attention" : "")")
    }

    @ViewBuilder private var rowMenuItems: some View {
        Button("Open claude.ai", action: open)
        Button("Open usage page", action: openUsage)
        Button(flagged ? "Clear attention flag" : "Flag for attention", action: toggleFlag)
        Button("Edit…", action: edit)
        if moveUp != nil || moveDown != nil {
            Divider()
            if let moveUp { Button("Move Up", action: moveUp) }
            if let moveDown { Button("Move Down", action: moveDown) }
        }
        Divider()
        Button("Remove account", role: .destructive, action: remove)
    }

    private var healthDescription: String {
        switch state {
        case .ok(let u):
            return "session \(Int(u.session?.utilization ?? 0)) percent used"
                + (u.anyLimitCapped ? ", limit reached" : "")
        case .stale(let u, let problem):
            return "session \(Int(u.session?.utilization ?? 0)) percent used, \(problem.display)"
        case .problem(let problem): return problem.display
        case .loading, .unknown: return "loading"
        }
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .ok(let u):
            usageMetrics(u)
        case .stale(let u, let problem):
            VStack(alignment: .leading, spacing: 5 * s) {
                usageMetrics(u)
                problemLine(problem)
            }
        case .loading, .unknown:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading…").font(.system(size: 11 * s)).foregroundStyle(.secondary)
            }.frame(height: 20 * s)
        case .problem(let problem):
            problemLine(problem)
        }
    }

    @ViewBuilder private func usageMetrics(_ u: AccountUsage) -> some View {
        let session = u.session?.utilization ?? 0
        VStack(alignment: .leading, spacing: 4 * s) {
            // Session — the primary metric, full-size bar.
            HStack {
                Text("Session").font(.system(size: 10 * s)).foregroundStyle(.secondary)
                Spacer()
                Text(resetString(u.session?.resetsAt))
                    .font(.system(size: 9 * s)).foregroundStyle(.secondary)
                Text(Prefs.pctLabel(session))
                    .font(.system(size: 10 * s, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(usageColor(session))
            }
            UsageBar(pct: session)
            if let cap = u.projectedCap {
                Label("At this pace, caps \(cap.formatted(date: .omitted, time: .shortened))",
                      systemImage: "speedometer")
                    .font(.system(size: 9 * s)).foregroundStyle(.orange)
            }
            // Weekly + per-model caps (e.g. Fable) — compact aligned lines.
            if let weekly = u.weekly {
                MetricLine(label: "Weekly", metric: weekly)
            }
            ForEach(Array(u.scoped.enumerated()), id: \.offset) { _, scope in
                MetricLine(label: scope.name, metric: scope.metric)
            }
            if let extra = u.extra {
                MetricLine(label: "Extra",
                           metric: UsageMetric(utilization: extra.percent, resetsAt: nil),
                           trailing: extra.usedDisplay ?? "")
            }
        }
    }

    @ViewBuilder private func problemLine(_ problem: UsageProblem) -> some View {
        HStack(spacing: 5 * s) {
            Image(systemName: problem.needsSignIn ? "exclamationmark.triangle.fill" : "arrow.clockwise")
                .font(.system(size: 10 * s, weight: .semibold))
            Text(problem.display)
                .font(.system(size: 10 * s))
                .lineLimit(2)
            if problem.needsSignIn {
                Button("Sign in again", action: edit)
                    .buttonStyle(.borderless)
                    .font(.system(size: 10 * s, weight: .medium))
            } else if problem.isTransient || problem == .accessDenied {
                Button("Retry", action: retry)
                    .buttonStyle(.borderless)
                    .font(.system(size: 10 * s, weight: .medium))
            }
        }
        .foregroundStyle(problem.needsSignIn ? Color.red : problem.isTransient ? Color.orange : Color.secondary)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var statusBadge: some View {
        switch state {
        case .ok(let u):
            let five = u.session?.utilization ?? 0
            // Shape doubles the meaning at high usage so it isn't color-only.
            if five >= 90 {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 9 * s)).foregroundStyle(.red)
            } else {
                Circle().fill(usageColor(five)).frame(width: 7 * s, height: 7 * s)
            }
        case .stale(_, let problem):
            Image(systemName: problem.needsSignIn ? "exclamationmark.triangle.fill" : "arrow.clockwise")
                .font(.system(size: 9 * s))
                .foregroundStyle(problem.needsSignIn ? Color.red : Color.orange)
        case .problem(let problem):
            Image(systemName: problem.needsSignIn ? "exclamationmark.triangle.fill" : "arrow.clockwise")
                .font(.system(size: 9 * s))
                .foregroundStyle(problem.needsSignIn ? Color.red : Color.orange)
        default:
            EmptyView()
        }
    }
}

// MARK: - Claude Code session lines (inline on the owning account's card)

struct CCSessionLines: View {
    var sessions: [CCSession]
    @Environment(\.dashScale) private var s

    var body: some View {
        VStack(alignment: .leading, spacing: 2 * s) {
            ForEach(sessions) { session in
                HStack(spacing: 5) {
                    Image(systemName: "terminal")
                        .font(.system(size: 8 * s))
                        .foregroundStyle(session.waiting ? .orange : .secondary)
                    Text("Claude Code · \(session.projectDisplay)")
                        .font(.system(size: 10 * s)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(session.waiting ? "waiting for your input" : relative(session.lastActivity))
                        .font(.system(size: 9 * s))
                        .foregroundStyle(session.waiting ? .orange : .secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Claude Code in \(session.projectDisplay): \(session.waiting ? "waiting for your input" : "active recently")")
            }
        }
    }

    private func relative(_ d: Date) -> String {
        let mins = Int(-d.timeIntervalSinceNow) / 60
        if mins < 1 { return "active now" }
        if mins < 60 { return "\(mins)m ago" }
        return "\(mins / 60)h ago"
    }
}

// MARK: - Claude Code section (fallback ONLY for sessions whose CLI login org
// matches no board account)

struct ClaudeCodeSection: View {
    var sessions: [CCSession]
    @Environment(\.dashScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 5 * scale) {
            Text("CLAUDE CODE")
                .font(.system(size: 9 * scale, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(sessions) { s in
                HStack(spacing: 6 * scale) {
                    Circle()
                        .fill(s.waiting ? Color.orange : activityColor(s))
                        .frame(width: 7 * scale, height: 7 * scale)
                    Text(s.projectDisplay).font(.system(size: 11 * scale, weight: .medium))
                    Spacer()
                    Text(s.waiting ? "waiting for your input" : relative(s.lastActivity))
                        .font(.system(size: 10 * scale))
                        .foregroundStyle(s.waiting ? .orange : .secondary)
                }
                .accessibilityLabel("Claude Code in \(s.projectDisplay): \(s.waiting ? "waiting for your input" : "active \(relative(s.lastActivity))")")
            }
        }
        .padding(.horizontal, 12 * scale).padding(.vertical, 9 * scale)
    }

    private func activityColor(_ s: CCSession) -> Color {
        -s.lastActivity.timeIntervalSinceNow < 180 ? .green : .secondary.opacity(0.5)
    }

    private func relative(_ d: Date) -> String {
        let mins = Int(-d.timeIntervalSinceNow) / 60
        if mins < 1 { return "active now" }
        if mins < 60 { return "\(mins)m ago" }
        return "\(mins / 60)h ago"
    }
}

// MARK: - Codex usage (local read from ~/.codex; nothing leaves the machine)

/// The Codex account's rate-limit window(s) as at-a-glance gauges, mirroring the
/// per-account Claude metrics. Reuses `MetricLine`; the "as of" age is honest
/// about this being a last-known local snapshot (Codex only writes it on a turn).
struct CodexSection: View {
    var usage: CodexUsage
    var tick: Int = 0   // recompute the "as of" age on the minute pulse
    var noteText: String = ""
    var noteChanged: (String) -> Void = { _ in }
    var noteCommitted: () -> Void = {}
    @Environment(\.dashScale) private var s

    var body: some View {
        VStack(alignment: .leading, spacing: 5 * s) {
            HStack(spacing: 6 * s) {
                Text("CODEX")
                    .font(.system(size: 9 * s, weight: .semibold)).foregroundStyle(.secondary)
                if let plan = usage.planType, !plan.isEmpty {
                    Text(plan.uppercased())
                        .font(.system(size: 8 * s, weight: .semibold))
                        .padding(.horizontal, 4 * s).padding(.vertical, 1 * s)
                        .background(Capsule().fill(Color.primary.opacity(0.1)))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if stale {
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(.system(size: 8 * s)).foregroundStyle(.orange)
                        .accessibilityHidden(true)
                }
                Text(agoText)
                    .font(.system(size: 8 * s))
                    .foregroundStyle(stale ? Color.orange : .secondary)
            }
            if let email = usage.accountEmail, !email.isEmpty {
                Text(email).font(.system(size: 10 * s)).foregroundStyle(.secondary).lineLimit(1)
            }
            // trailing: recomputes resetString each minute pulse (via `tick`) so
            // the countdown keeps ticking while Codex is idle and the snapshot,
            // hence the metric, is unchanged.
            ForEach(Array(usage.windows.enumerated()), id: \.offset) { _, window in
                MetricLine(label: window.label, metric: window.metric,
                           trailing: resetString(window.metric.resetsAt))
            }
            NoteView(text: noteText,
                     placeholder: "What am I working on here…",
                     onChange: noteChanged,
                     onCommit: noteCommitted)
        }
        .padding(.horizontal, 12 * s).padding(.vertical, 9 * s)
        .cappedDim(capped)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Codex usage" + (usage.accountEmail.map { ", \($0)" } ?? "")
                            + (capped ? ", limit reached" : "")
                            + (stale ? ", reading may be out of date" : ""))
    }

    /// Recomputed on the minute pulse (`tick` re-renders), so the dim lifts on
    /// its own once a capped window's reset time passes.
    private var capped: Bool {
        usage.windows.contains { $0.isCurrentlyCapped() }
    }

    /// A stale reading: the snapshot is over an hour old, or a window's own
    /// countdown has already elapsed (so the shown percent predates a reset).
    private var stale: Bool {
        -usage.snapshotAt.timeIntervalSinceNow > 3600
            || usage.windows.contains { $0.metric.resetsAt.map { $0 <= Date() } ?? false }
    }

    private var agoText: String {
        let mins = Int(-usage.snapshotAt.timeIntervalSinceNow) / 60
        if mins < 1 { return "just now" }
        if mins < 60 { return "as of \(mins)m ago" }
        let hrs = mins / 60
        if hrs < 24 { return "as of \(hrs)h ago" }
        return "as of \(hrs / 24)d ago"
    }
}

// MARK: - Menu bar gauges (rendered to an image)

struct MenuBarGaugesView: View {
    var accounts: [Account]
    var usage: [String: UsageState]
    var mode: Prefs.MenuBarMode = .all
    var attention: Bool = false

    var body: some View {
        HStack(spacing: 7) {
            if attention {
                Circle().fill(Color.orange).frame(width: 5, height: 5)
                    .accessibilityLabel("Something needs your attention")
            }
            switch mode {
            case .icon:
                gaugeGlyph
            case .tightest:
                if let a = tightest { chip(a) } else { gaugeGlyph }
            case .all:
                if accounts.isEmpty {
                    gaugeGlyph
                } else {
                    ForEach(accounts) { a in chip(a) }
                }
            }
        }
        .padding(.horizontal, 2)
        .accessibilityLabel("Claude Dash usage gauges")
    }

    private var gaugeGlyph: some View {
        HStack(spacing: 3) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.system(size: 13, weight: .medium))
            if accounts.isEmpty { Text("Dash").font(.system(size: 11, weight: .semibold)) }
        }
    }

    private var tightest: Account? {
        accounts.max { pct($0) ?? -1 < pct($1) ?? -1 }
    }

    private func pct(_ a: Account) -> Double? {
        usage[a.id]?.snapshot?.session?.utilization
    }

    @ViewBuilder private func chip(_ a: Account) -> some View {
        let initials = String(a.displayName.prefix(2)).uppercased()
        let state = usage[a.id] ?? .unknown
        VStack(spacing: 1) {
            Text(initials).font(.system(size: 7, weight: .semibold)).foregroundStyle(.primary)
            switch state {
            case .ok(let u):
                let pct = u.session?.utilization ?? 0
                miniBar(pct)
            case .stale(let u, let problem):
                if problem.needsSignIn {
                    Image(systemName: "exclamationmark").font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.red).frame(height: 3)
                } else {
                    miniBar(u.session?.utilization ?? 0).opacity(0.55)
                }
            case .problem(let problem) where problem.needsSignIn:
                // Distinct from a 100%-full red bar so a confirmed sign-in
                // problem cannot be mistaken for maxed-out usage.
                Image(systemName: "exclamationmark").font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.red).frame(height: 3)
            default:
                Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 15, height: 3).cornerRadius(1.5)
            }
        }
    }

    private func miniBar(_ pct: Double) -> some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(Color.primary.opacity(0.18)).frame(width: 15, height: 3)
            Rectangle().fill(usageColor(pct)).frame(width: max(0, min(1, pct/100)) * 15, height: 3)
        }.cornerRadius(1.5)
    }
}

// MARK: - Add account

struct AddAccountView: View {
    @ObservedObject var model: AppModel
    var onDone: () -> Void

    @State private var sessionKey = ""
    @State private var validating = false
    @State private var committing = false
    @State private var orgs: [Org] = []
    @State private var selectedOrg: Org?
    @State private var profiles: [ChromeProfile] = ChromeProfiles.all()
    @State private var selectedProfile: ChromeProfile?
    @State private var displayName = ""
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Claude account").font(.system(size: 15, weight: .semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("Session key").font(.system(size: 11, weight: .medium))
                HStack(spacing: 6) {
                    SecureField("sk-ant-sid…", text: $sessionKey)
                        .textFieldStyle(.roundedBorder)
                    Button("Sign in…") {
                        SignInWindow.present { key in
                            sessionKey = key
                            validate()
                        }
                    }
                    .help("Log in to claude.ai in a window — the key is captured automatically")
                }
                Text("Easiest: click Sign in… and log into the account. Manual: in that browser profile, open claude.ai → DevTools (⌥⌘I) → Application → Cookies → https://claude.ai → copy the sessionKey value.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let errorText {
                Text(errorText).font(.system(size: 11)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !orgs.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Organization").font(.system(size: 11, weight: .medium))
                    Picker("", selection: $selectedOrg) {
                        ForEach(orgs) { o in
                            Text(o.isChatOrg ? o.name : "\(o.name) — API org, no chat usage")
                                .tag(Optional(o))
                        }
                    }.labelsHidden()
                    if orgs.count > 1 {
                        Text("This login has \(orgs.count) organizations. Pick the one whose usage you want to track — it's verified before saving.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(BrowserDetect.current().appName) profile").font(.system(size: 11, weight: .medium))
                    if profiles.isEmpty {
                        Text("No \(BrowserDetect.current().appName) profiles found. Claude Dash opens each account in its own browser profile — install/sign into Chrome, Brave, or Edge, or set a browser override (see the README).")
                            .font(.system(size: 10)).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Picker("", selection: $selectedProfile) {
                            Text("Choose…").tag(Optional<ChromeProfile>.none)
                            ForEach(profiles) { p in Text(p.label).tag(Optional(p)) }
                        }.labelsHidden()
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Display name").font(.system(size: 11, weight: .medium))
                    TextField("Name shown in the dashboard", text: $displayName)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack {
                Button("Cancel", action: onDone).keyboardShortcut(.cancelAction)
                Spacer()
                if orgs.isEmpty {
                    Button(validating ? "Validating…" : "Validate key", action: validate)
                        .keyboardShortcut(.defaultAction)
                        .disabled(sessionKey.isEmpty || validating)
                } else {
                    Button(committing ? "Verifying usage…" : "Add account", action: commit)
                        .keyboardShortcut(.defaultAction)
                        .disabled(selectedOrg == nil || selectedProfile == nil || committing)
                }
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func validate() {
        errorText = nil
        validating = true
        let key = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                let found = try await UsageAPI.organizations(sessionKey: key)
                await MainActor.run {
                    orgs = found
                    selectedOrg = found.first(where: { $0.isChatOrg }) ?? found.first
                    if displayName.isEmpty { displayName = selectedOrg?.name ?? "" }
                    validating = false
                }
            } catch let e as UsageError {
                await MainActor.run { errorText = e.display; validating = false }
            } catch {
                await MainActor.run { errorText = error.localizedDescription; validating = false }
            }
        }
    }

    private func commit() {
        let key = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let org = selectedOrg, let profile = selectedProfile else { return }
        errorText = nil
        committing = true
        Task {
            do {
                // Pre-flight: prove the usage endpoint answers for THIS key + org
                // before saving, so a wrong-org pick fails here with the real reason.
                _ = try await UsageAPI.usage(sessionKey: key, orgUuid: org.uuid)
                await MainActor.run {
                    committing = false
                    model.addAccount(sessionKey: key, org: org, profile: profile, displayName: displayName)
                    onDone()
                }
            } catch let e as UsageError {
                await MainActor.run {
                    committing = false
                    errorText = "Usage check failed for “\(org.name)”: \(e.display)." +
                        (orgs.count > 1 ? " Try a different organization from the list." : "")
                }
            } catch {
                await MainActor.run { committing = false; errorText = error.localizedDescription }
            }
        }
    }
}

// MARK: - Edit account

struct EditAccountView: View {
    @ObservedObject var model: AppModel
    var account: Account
    var onDone: () -> Void
    var onRemove: (Account) -> Void = { _ in }

    @State private var displayName: String
    @State private var profiles: [ChromeProfile] = ChromeProfiles.all()
    @State private var selectedProfile: ChromeProfile?
    @State private var newKey = ""
    @State private var saving = false
    @State private var errorText: String?

    init(model: AppModel, account: Account, onDone: @escaping () -> Void,
         onRemove: @escaping (Account) -> Void = { _ in }) {
        self.model = model
        self.account = account
        self.onDone = onDone
        self.onRemove = onRemove
        _displayName = State(initialValue: account.displayName)
        let all = ChromeProfiles.all()
        _profiles = State(initialValue: all)
        _selectedProfile = State(initialValue: all.first(where: { $0.dir == account.chromeProfileDir }))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit account").font(.system(size: 15, weight: .semibold))
            Text("\(account.orgName) — the organization is fixed; to track a different one, remove this account and add it again.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                Text("Display name").font(.system(size: 11, weight: .medium))
                TextField("", text: $displayName).textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("\(BrowserDetect.current().appName) profile").font(.system(size: 11, weight: .medium))
                if profiles.isEmpty {
                    Text("No \(BrowserDetect.current().appName) profiles found — install/sign into a Chromium browser or set a browser override (see the README).")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Picker("", selection: $selectedProfile) {
                        ForEach(profiles) { p in Text(p.label).tag(Optional(p)) }
                    }.labelsHidden()
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Replace session key (optional)").font(.system(size: 11, weight: .medium))
                HStack(spacing: 6) {
                    SecureField("Leave blank to keep the current key", text: $newKey)
                        .textFieldStyle(.roundedBorder)
                    Button("Sign in…") {
                        SignInWindow.present { key in newKey = key }
                    }
                    .help("Log in to claude.ai in a window — the key is captured automatically")
                }
            }

            if let errorText {
                Text(errorText).font(.system(size: 11)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button(role: .destructive) { onRemove(account) } label: { Text("Remove account") }
                Spacer()
                Button("Cancel", action: onDone).keyboardShortcut(.cancelAction)
                Button(saving ? "Verifying…" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func save() {
        let key = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        errorText = nil
        guard !key.isEmpty else {
            model.updateAccount(id: account.id, displayName: displayName,
                                profile: selectedProfile, newSessionKey: nil)
            onDone()
            return
        }
        saving = true
        Task {
            do {
                // Pre-flight the replacement key against this account's org.
                _ = try await UsageAPI.usage(sessionKey: key, orgUuid: account.orgUuid)
                await MainActor.run {
                    saving = false
                    model.updateAccount(id: account.id, displayName: displayName,
                                        profile: selectedProfile, newSessionKey: key)
                    onDone()
                }
            } catch let e as UsageError {
                await MainActor.run {
                    saving = false
                    errorText = "This key can't read usage for “\(account.orgName)”: \(e.display). Paste a key from the login that owns this account — or remove the account and re-add it."
                }
            } catch {
                await MainActor.run { saving = false; errorText = error.localizedDescription }
            }
        }
    }
}

// MARK: - Preferences

struct PreferencesView: View {
    var model: AppModel
    var onLoginItemToggle: (Bool) -> Void
    var loginItemEnabled: () -> Bool
    var onCheckUpdates: () -> Void

    @State private var pollInterval = Prefs.pollInterval
    @State private var notifyThreshold = Prefs.notifyThreshold
    @State private var notifyOnReset = Prefs.notifyOnReset
    @State private var showRemaining = Prefs.showRemaining
    @State private var sortMode = Prefs.sortMode
    @State private var menuBarMode = Prefs.menuBarMode
    @State private var hotkeyEnabled = Prefs.hotkeyEnabled
    @State private var launchAtLogin = false
    @State private var boardFloats = Prefs.boardFloats
    @State private var boardTextScale = Prefs.boardTextScale
    @State private var hooksInstalled = ClaudeCodeMonitor.hooksInstalled()
    @State private var hooksError: String?
    @State private var monitorCodex = Prefs.monitorCodex

    var body: some View {
        Form {
            Section {
                Picker("Refresh every", selection: $pollInterval) {
                    Text("30 seconds").tag(30.0)
                    Text("1 minute").tag(60.0)
                    Text("2 minutes").tag(120.0)
                    Text("5 minutes").tag(300.0)
                }
                Picker("Sort accounts", selection: $sortMode) {
                    ForEach(Prefs.SortMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Menu bar shows", selection: $menuBarMode) {
                    ForEach(Prefs.MenuBarMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("Show remaining % instead of used %", isOn: $showRemaining)
            }
            Section {
                Toggle("Board window stays on top", isOn: $boardFloats)
                Picker("Board text size", selection: $boardTextScale) {
                    Text("Standard").tag(1.0)
                    Text("Large").tag(1.25)
                    Text("X-Large").tag(1.5)
                }
                HStack {
                    Text(hooksInstalled
                         ? "Claude Code hooks installed — active sessions and “waiting for your input” show on the board"
                         : "Show Claude Code sessions on the board (“waiting for your input”) — installs two local hooks")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(hooksInstalled ? "Remove" : "Install…") {
                        do {
                            if hooksInstalled { try ClaudeCodeMonitor.uninstallHooks() }
                            else { try ClaudeCodeMonitor.installHooks() }
                            hooksInstalled = ClaudeCodeMonitor.hooksInstalled()
                            hooksError = nil
                        } catch {
                            hooksError = error.localizedDescription
                        }
                    }
                    .controlSize(.small)
                }
                if let hooksError {
                    Text(hooksError).font(.system(size: 10)).foregroundStyle(.red)
                }
                Toggle("Show Codex usage (reads ~/.codex locally — no keys, no network)",
                       isOn: $monitorCodex)
            }
            Section {
                Picker("Notify at", selection: $notifyThreshold) {
                    Text("Off").tag(0)
                    Text("75% of session").tag(75)
                    Text("90% of session").tag(90)
                    Text("95% of session").tag(95)
                }
                Toggle("Notify when a capped session resets", isOn: $notifyOnReset)
            }
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                Toggle("Global hotkey ⌃⌥⌘D toggles the board window", isOn: $hotkeyEnabled)
            }
            Section {
                Button("Check for Updates…", action: onCheckUpdates)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { launchAtLogin = loginItemEnabled() }
        .onChange(of: pollInterval) { v in Prefs.pollInterval = v; model.applyPrefsChange() }
        .onChange(of: notifyThreshold) { v in Prefs.notifyThreshold = v }
        .onChange(of: notifyOnReset) { v in Prefs.notifyOnReset = v }
        .onChange(of: showRemaining) { v in Prefs.showRemaining = v; model.objectWillChange.send() }
        .onChange(of: sortMode) { v in Prefs.sortMode = v; model.objectWillChange.send() }
        .onChange(of: menuBarMode) { v in Prefs.menuBarMode = v; model.objectWillChange.send() }
        .onChange(of: hotkeyEnabled) { v in Prefs.hotkeyEnabled = v; model.objectWillChange.send() }
        .onChange(of: launchAtLogin) { v in onLoginItemToggle(v) }
        .onChange(of: monitorCodex) { v in Prefs.monitorCodex = v; model.refreshCodex() }
        .onChange(of: boardFloats) { v in Prefs.boardFloats = v; model.objectWillChange.send() }
        .onChange(of: boardTextScale) { v in Prefs.boardTextScale = v; model.objectWillChange.send() }
    }
}
