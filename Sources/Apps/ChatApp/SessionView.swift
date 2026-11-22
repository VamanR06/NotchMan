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

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if transcript.isLoaded && transcript.entries.isEmpty {
                        note("Nothing in this session yet.")
                    } else if !transcript.isLoaded {
                        note("Reading the session…")
                    }
                    ForEach(transcript.entries) { entry in
                        row(entry)
                    }
                    ForEach(approvals) { request in
                        ApprovalCard(app: app, request: request)
                    }
                    if isWorking && approvals.isEmpty {
                        HStack(spacing: 6) {
                            NotchSpinner(size: 11, lineWidth: 1.6)
                            Text("Working…").font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                        }
                    }
                    Color.clear.frame(height: 1).id(Self.bottom)
                }
                .padding(10)
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.04)))
            .onAppear { proxy.scrollTo(Self.bottom, anchor: .bottom) }
            .onChange(of: transcript.entries.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
            }
            .onChange(of: approvals.count) { _, _ in proxy.scrollTo(Self.bottom, anchor: .bottom) }
        }
    }

    private static let bottom = "bottom"

    @ViewBuilder private func row(_ entry: TranscriptEntry) -> some View {
        switch entry.kind {
        case .prompt(let text):
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .textSelection(.enabled)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.accentColor.opacity(0.3)))
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .reply(let text):
            MarkdownLines(lines: text.components(separatedBy: "\n"))
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.92))
        case .tool(let call):
            ToolCallRow(call: call, cwd: terminal.agent.cwd) { path in
                guard let mention = FileMentions.resolve(path, in: terminal.agent.cwd) else { return }
                withAnimation(.easeOut(duration: 0.15)) { preview = FilePreview(mention: mention) }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).frame(maxWidth: .infinity)
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(spacing: 6) {
            TextField(terminal.isRunning ? "Message \(terminal.agent.name)…" : "Detached — reattach to send",
                      text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
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
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 18))
                }
                .buttonStyle(.plain)
                .foregroundStyle(draft.isEmpty ? .white.opacity(0.3) : Color.accentColor)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Send (Return)")
            } else {
                Button("Reattach") { app.reattach(terminal) }.controlSize(.small)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.08)))
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

/// One tool call: an icon, what it did, and whether it's running, done or failed. Click to see the details —
/// the command and its output, an edit as a diff, the file it wrote.
private struct ToolCallRow: View {
    let call: ToolCall
    let cwd: String
    let preview: (String) -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Image(systemName: Self.symbol(call.name))
                    .font(.system(size: 10))
                    .frame(width: 14)
                    .foregroundStyle(.white.opacity(0.6))
                Text(call.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                Text(call.summary)
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
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(expanded ? 0.07 : 0.035)))
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
