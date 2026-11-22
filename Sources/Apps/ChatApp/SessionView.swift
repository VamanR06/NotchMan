import AppKit
import NotchKit
import SwiftUI

/// A background agent's session drawn natively: what you asked, Claude's answers, each tool call as a row you can
/// open, this session's approvals, and a box to message it. Claude Code's own terminal stays a tab away.
struct AgentSessionView: View {
    let app: ChatApp
    @Bindable var terminal: AgentTerminal
    @State private var draft = ""
    @State private var preview: FilePreview?
    @FocusState private var composerFocused: Bool

    private var transcript: SessionTranscript { terminal.transcript }
    private var approvals: [ApprovalRequest] { app.approvals.filter { $0.sessionID == terminal.agent.id } }
    private var isWorking: Bool { terminal.agent.status == "busy" || terminal.agent.phase == .working }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                conversation
                if let preview {
                    FilePreviewOverlay(preview: preview) { withAnimation(.easeOut(duration: 0.15)) { self.preview = nil } }
                        .id(preview.id)
                }
            }
            composer
        }
        .task(id: terminal.id) { await transcript.follow() }
    }

    // MARK: - Conversation

    @State private var atBottom = true
    @State private var unseenBelow = false

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if transcript.isLoaded && transcript.entries.isEmpty {
                        note("Nothing in this session yet.")
                    } else if !transcript.isLoaded {
                        note("Reading the session…")
                    }
                    ForEach(SessionItem.items(transcript.entries)) { item in
                        row(item)
                    }
                    ForEach(approvals) { request in
                        ApprovalCard(app: app, request: request)
                    }
                    if isWorking && approvals.isEmpty {
                        Gutter(mark: "✻", color: .orange) {
                            HStack(spacing: 6) {
                                Text((app.sessionActivity[terminal.agent.id].flatMap { $0.isFresh() ? $0.lastAction : nil } ?? "Working") + "…")
                                    .font(Self.mono).foregroundStyle(.orange.opacity(0.9))
                                NotchSpinner(size: 9, color: .orange.opacity(0.7), lineWidth: 1.4)
                            }
                        }
                    }
                    // Seen only when scrolled to the end: new rows follow along then, and leave you be otherwise.
                    Color.clear.frame(height: 1).id(Self.bottom)
                        .onAppear { atBottom = true; unseenBelow = false }
                        .onDisappear { atBottom = false }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
            }
            // A terminal's black, with the faint frame the notch's terminals have.
            .background(RoundedRectangle(cornerRadius: 10).fill(.black))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.1)))
            .overlay(alignment: .bottom) {
                if unseenBelow {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
                    } label: {
                        Label("New messages", systemImage: "arrow.down").font(.system(size: 10.5, weight: .medium))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Capsule().fill(Color.accentColor))
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .onAppear { proxy.scrollTo(Self.bottom, anchor: .bottom) }
            .onChange(of: transcript.entries.count) { _, _ in
                if atBottom {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
                } else {
                    withAnimation(.easeOut(duration: 0.15)) { unseenBelow = true }
                }
            }
            .onChange(of: approvals.count) { _, _ in proxy.scrollTo(Self.bottom, anchor: .bottom) }
        }
    }

    private static let bottom = "bottom"
    static let mono = Font.system(size: 11.5, design: .monospaced)

    /// Laid out like Claude Code's own terminal: a marker in the gutter (❯ you, ⏺ Claude, ⎿ its steps), everything
    /// left-aligned — but replies drawn as Markdown, so tables and lists read properly.
    @ViewBuilder private func row(_ item: SessionItem) -> some View {
        switch item {
        case .prompt(_, let text):
            Gutter(mark: "❯", color: .white.opacity(0.55)) {
                Text(text)
                    .font(Self.mono)
                    .foregroundStyle(.white.opacity(0.95))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 5)
            .background(Rectangle().fill(.white.opacity(0.06)).padding(.horizontal, -12))
            .padding(.top, 6)
        case .reply(_, let text):
            Gutter(mark: "⏺", color: .white.opacity(0.85)) {
                MarkdownView(text: text)
            }
        case .steps(_, let calls):
            Gutter(mark: "⎿", color: .white.opacity(0.3)) {
                ToolStepsRow(calls: calls, preview: previewFile)
            }
        }
    }

    private func previewFile(_ path: String) {
        guard let mention = FileMentions.resolve(path, in: terminal.agent.cwd) else { return }
        withAnimation(.easeOut(duration: 0.15)) { preview = FilePreview(mention: mention) }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).frame(maxWidth: .infinity)
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("❯").font(Self.mono).foregroundStyle(.white.opacity(composerFocused ? 0.9 : 0.5))
            TextField(terminal.isRunning ? "Message \(terminal.agent.name)…" : "Detached — reattach to send",
                      text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Self.mono)
                .lineLimit(1...4)
                .focused($composerFocused)
                .disabled(!terminal.isRunning)
                .onSubmit(send)
                .onKeyPress(.leftArrow) {
                    // ← in an empty box goes back, like ← from Claude's empty prompt.
                    guard draft.isEmpty else { return .ignored }
                    app.backToOverview()
                    return .handled
                }
            if terminal.isRunning {
                Text(draft.isEmpty ? "" : "↩ send")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.35))
            } else {
                Button("Reattach") { app.reattach(terminal) }.controlSize(.small)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        // Claude Code's input box: a rule above and below.
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(composerFocused ? 0.3 : 0.15)).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(composerFocused ? 0.3 : 0.15)).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture { composerFocused = true }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, terminal.isRunning else { return }
        terminal.sendToClaude(text)
        draft = ""
    }
}

/// A row with a terminal-style marker in a narrow gutter and its content beside it.
private struct Gutter<Content: View>: View {
    let mark: String
    let color: Color
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(mark)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(color)
                .frame(width: 12, alignment: .center)
            content
        }
    }
}

/// What the session view shows: your prompts, Claude's replies, and the tool calls between them as one group of steps.
enum SessionItem: Identifiable {
    case prompt(id: String, String)
    case reply(id: String, String)
    case steps(id: String, [ToolCall])

    var id: String {
        switch self {
        case .prompt(let id, _), .reply(let id, _), .steps(let id, _): id
        }
    }

    /// Entries with each run of tool calls gathered into one item.
    static func items(_ entries: [TranscriptEntry]) -> [SessionItem] {
        var items: [SessionItem] = []
        for entry in entries {
            switch entry.kind {
            case .prompt(let text): items.append(.prompt(id: entry.id, text))
            case .reply(let text): items.append(.reply(id: entry.id, text))
            case .tool(let call):
                if case .steps(let id, let calls)? = items.last {
                    items[items.count - 1] = .steps(id: id, calls + [call])
                } else {
                    items.append(.steps(id: entry.id, [call]))
                }
            }
        }
        return items
    }
}

/// A run of tool calls as one quiet line — how many steps, the latest one, and whether any is running or failed —
/// that opens into a row per call.
private struct ToolStepsRow: View {
    let calls: [ToolCall]
    let preview: (String) -> Void
    @State private var expanded = false

    private var running: Bool { calls.contains { !$0.isFinished } }
    private var failures: Int { calls.filter(\.isError).count }

    var body: some View {
        if calls.count == 1, let call = calls.first {
            ToolCallRow(call: call, preview: preview)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(width: 10)
                    Text("\(calls.count) steps").font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                    if let last = calls.last {
                        Text("·").foregroundStyle(.white.opacity(0.3))
                        Text(ToolCallRow.describe(last))
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.45))
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    if failures > 0 {
                        Label("\(failures)", systemImage: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(.red.opacity(0.85))
                    }
                    if running {
                        NotchSpinner(size: 10, lineWidth: 1.5)
                    } else if failures == 0 {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.green.opacity(0.7))
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } }
                if expanded {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(calls.enumerated()), id: \.offset) { _, call in
                            ToolCallRow(call: call, preview: preview)
                        }
                    }
                    .padding(.leading, 12)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

/// One tool call: an icon, what it did, and whether it's running, done or failed. Click to see the details —
/// the command and its output, an edit as a diff, the file it wrote.
private struct ToolCallRow: View {
    let call: ToolCall
    let preview: (String) -> Void
    @State private var expanded = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Image(systemName: Self.symbol(call.name))
                    .font(.system(size: 10))
                    .frame(width: 14)
                    .foregroundStyle(.white.opacity(0.45))
                Text(Self.describe(call))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if let path = call.path {
                    Button { preview(path) } label: { Image(systemName: "eye").font(.system(size: 10)) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.55))
                        .help("Preview \(URL(fileURLWithPath: path).lastPathComponent)")
                }
                status
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } }
            if expanded { detail.padding(.leading, 21) }
        }
        .padding(.horizontal, 4).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(expanded ? 0.06 : hovering ? 0.04 : 0)))
        .onHover { hovering = $0 }
    }

    /// What the call did, in a few words: "Edited ShelfView.swift", "Run the tests", "Searched “TODO”".
    static func describe(_ call: ToolCall) -> String {
        let file = call.path.map { ($0 as NSString).lastPathComponent }
        switch call.name {
        case "Edit", "MultiEdit", "NotebookEdit": return "Edited " + (file ?? call.summary)
        case "Write": return "Wrote " + (file ?? call.summary)
        case "Read": return "Read " + (file ?? call.summary)
        case "Bash": return call.summary.isEmpty ? "Ran a command" : call.summary
        case "Grep", "Glob": return "Searched “\(call.summary)”"
        case "WebSearch": return "Searched the web for “\(call.summary)”"
        case "WebFetch": return "Read " + (URL(string: call.summary)?.host ?? call.summary)
        case "Agent", "Task": return "Subagent: " + call.summary
        case "TodoWrite": return "Updated the plan"
        default: return call.summary.isEmpty ? call.name : "\(call.name): \(call.summary)"
        }
    }

    @ViewBuilder private var status: some View {
        if !call.isFinished {
            NotchSpinner(size: 10, lineWidth: 1.5)
        } else if call.isError {
            Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(.red)
        } else {
            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.green.opacity(0.8))
        }
    }

    @ViewBuilder private var detail: some View {
        switch call.detail {
        case .command(let command):
            mono("$ " + command, color: .white.opacity(0.85))
            if let result = call.result, !result.isEmpty { mono(result, color: .white.opacity(0.6)) }
        case .edit(_, let old, let new):
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(Self.diffLines(old: old, new: new).enumerated()), id: \.offset) { _, line in
                    mono(line.text, color: line.added ? .green : .red)
                        .background((line.added ? Color.green : Color.red).opacity(0.1))
                }
            }
        case .write(_, let content):
            mono(Self.head(content, lines: 20), color: .white.opacity(0.75))
        case .read, .search, .other:
            if let result = call.result, !result.isEmpty {
                mono(Self.head(result, lines: 20), color: .white.opacity(0.6))
            }
        }
    }

    private func mono(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(color)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func head(_ text: String, lines: Int) -> String {
        let all = text.components(separatedBy: "\n")
        return all.count > lines ? all.prefix(lines).joined(separator: "\n") + "\n…" : text
    }

    /// The replaced lines then the new ones, as `- ` / `+ ` rows (enough to see what an edit did).
    static func diffLines(old: String, new: String) -> [(text: String, added: Bool)] {
        let removed = old.isEmpty ? [] : old.components(separatedBy: "\n").prefix(15).map { ("- " + $0, false) }
        let added = new.isEmpty ? [] : new.components(separatedBy: "\n").prefix(15).map { ("+ " + $0, true) }
        return removed + added
    }

    static func symbol(_ tool: String) -> String {
        switch tool {
        case "Bash": "terminal"
        case "Read": "doc.text"
        case "Edit", "NotebookEdit": "pencil"
        case "Write": "square.and.pencil"
        case "Grep", "Glob": "magnifyingglass"
        case "WebFetch", "WebSearch": "globe"
        case "Agent", "Task": "person.2"
        case "TodoWrite": "checklist"
        default: "wrench.and.screwdriver"
        }
    }
}
