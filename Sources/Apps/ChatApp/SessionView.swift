import AppKit
import NotchKit
import SwiftUI

/// A background agent's session drawn natively: what you asked, Claude's answers, each tool call as a row you can
/// open, this session's approvals, and a box to message it. Claude Code's own terminal stays a tab away.
struct AgentSessionView: View {
    let app: ChatApp
    @Bindable var terminal: AgentTerminal
    @State private var draft: String

    init(app: ChatApp, terminal: AgentTerminal, draft: String = "") {
        self.app = app
        self.terminal = terminal
        _draft = State(initialValue: draft)
    }
    @State private var preview: FilePreview?
    @FocusState private var composerFocused: Bool
    /// Images going with the next message (pasted with ⌘V or dropped on the session).
    @State private var images: [URL] = []
    @State private var pasteMonitor = ImagePasteMonitor()
    /// Typing a new quick command (the field shows in the bar above the message box).
    @State private var addingQuickCommand = false
    /// The reply Claude is writing, read off its terminal until the finished one reaches the session file.
    @State private var liveReply: String?
    /// Whether Claude's terminal shows its spinner; nil until it has been seen once in this terminal (so a screen
    /// that looks different never hides a turn that's really running).
    @State private var screenBusy: Bool?
    /// A choice Claude's terminal is waiting on (trust this folder, a question, a permission), shown as a card.
    @State private var claudePrompt: ClaudePrompt?
    /// Claude Code's permission mode from its footer ("Auto mode", "Plan mode").
    @State private var claudeMode: String?
    /// You pressed Esc while Claude worked: if it hadn't answered yet, your prompt comes back to the box (as Claude
    /// Code puts it back into its own input), and its row leaves the conversation.
    @State private var interruptedAt: Date?
    @State private var withdrawn: String?
    /// Going back through your earlier prompts with ↑ in the message box: how far back, and what you'd typed first.
    @State private var historyIndex: Int?
    @State private var draftBeforeHistory = ""
    /// A view Claude opened over its input (a background task's details), shown as a card.
    @State private var claudeScreen: ClaudeScreen?
    /// Background shells Claude's footer says are still running.
    @State private var backgroundShells = 0
    /// "/" commands and "@" files offered for what's being typed, and the highlighted one.
    @State private var suggestions: [ComposerSuggestion] = []
    @State private var suggestionIndex = 0
    /// The draft the suggestions were closed for (Esc), so they don't reopen until it changes.
    @State private var dismissedFor: String?

    private var transcript: SessionTranscript { terminal.transcript }
    private var approvals: [ApprovalRequest] { app.approvals.filter { $0.sessionID == terminal.agent.id } }
    /// Working, by the session file (a turn is open until Claude's last message of it lands), else by Claude's
    /// spinner in its attached terminal, else by what `claude agents` last said — which can stay "busy" after a turn.
    /// Working, by Claude's spinner in its attached terminal once it's been seen there (current to the moment, and it
    /// goes the instant you press Esc); else by the session file's turn markers; else by `claude agents`.
    private var isWorking: Bool { screenBusy ?? transcript.turnOpen ?? agentBusy }
    /// One of Claude's menus or prompts is showing: the keyboard drives it.
    private var menuOpen: Bool { claudePrompt != nil || claudeScreen != nil }

    private var agentBusy: Bool { terminal.agent.status == "busy" || terminal.agent.phase == .working }

    var body: some View {
        VStack(spacing: 6) {
            // An approved plan's steps (nothing ticks them off) show while Claude works on them; Claude's own list
            // stays while any of it is left.
            if !transcript.todos.isEmpty,
               isWorking || (!transcript.todosFromPlan && transcript.todos.contains { $0.status != .completed }) {
                PlanStrip(todos: transcript.todos, tracked: !transcript.todosFromPlan).transition(.opacity)
            }
            ZStack(alignment: .bottomLeading) {
                conversation
                if let preview {
                    FilePreviewOverlay(preview: preview) { withAnimation(.easeOut(duration: 0.15)) { self.preview = nil } }
                        .id(preview.id)
                }
                // Over the bottom of the conversation, just above the message box: inside the notch, and the box
                // keeps its size.
                if !suggestions.isEmpty {
                    SuggestionList(suggestions: suggestions, selected: suggestionIndex, pick: take)
                        .frame(maxWidth: 480, alignment: .leading)
                        .padding(.leading, 8).padding(.bottom, 6)
                        .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
                        .transition(.opacity)
                }
            }
            if let claudeScreen, claudePrompt == nil {
                ClaudeScreenCard(screen: claudeScreen) { keys in
                    terminal.claude.view.send(data: keys[...])
                    composerFocused = true  // the keyboard keeps driving the menu after a click
                }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if let claudePrompt {
                ClaudePromptCard(prompt: claudePrompt) { option in
                    terminal.claude.view.send(data: claudePrompt.keys(for: option)[...])
                    composerFocused = true
                    if option.isTextEntry { composerFocused = true }
                } cancel: {
                    terminal.claude.view.send(data: ClaudePrompt.cancelKey[...])
                } press: { keys in
                    terminal.claude.view.send(data: keys[...])
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            QuickCommandBar(folder: terminal.agent.cwd, adding: $addingQuickCommand) { command in
                terminal.runInShell(command)
            } runInTerminal: { command in
                ShellCommand.openInTerminal(command, in: terminal.agent.cwd)
            }
            composer
        }
        .task(id: terminal.id) { await transcript.follow() }
        .task(id: terminal.id) { await watchTerminal() }
        .onAppear {
            pasteMonitor.start(isActive: { composerFocused && terminal.isRunning }) { image in
                if let file = ImageAttachments.save(image) { images.append(file) }
            }
        }
        .onDisappear { pasteMonitor.stop() }
        .onAppear {
            refreshSuggestions()
            // Claude's terminal runs hidden behind this view: give it room, so its menus (/permissions' long list)
            // fit on its screen. The Terminal tab sizes it to the pane again when shown.
            let view = terminal.claude.view
            if view.window == nil, view.frame.height < 900 {
                view.setFrameSize(NSSize(width: max(view.frame.width, 680), height: 1000))
            }
        }
        .onChange(of: menuOpen) { _, open in
            // A menu opened (yours, or Claude asking): put the keyboard on it.
            if open { composerFocused = true }
        }
        .onChange(of: transcript.withdrawnPrompt) { _, text in
            guard let text, text != withdrawn else { return }
            restore(text)
        }
        .environment(\.commandRunner, CommandRunner(
            run: { [terminal] command in terminal.runInShell(command) },
            runInTerminal: { [terminal] command in ShellCommand.openInTerminal(command, in: terminal.agent.cwd) },
            save: { [terminal] command in QuickCommands.shared.add(command, for: terminal.agent.cwd) }))
        .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
            for provider in providers {
                if provider.canLoadObject(ofClass: URL.self) {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url, ImageAttachments.isImage(url) else { return }
                        Task { @MainActor in images.append(url) }
                    }
                } else if provider.canLoadObject(ofClass: NSImage.self) {
                    _ = provider.loadObject(ofClass: NSImage.self) { image, _ in
                        guard let image = image as? NSImage else { return }
                        Task { @MainActor in if let file = ImageAttachments.save(image) { images.append(file) } }
                    }
                }
            }
            return true
        }
    }

    // MARK: - Conversation

    /// Keeps the newest rows in view as they arrive; let go of when you scroll up, taken up again at the end.
    @State private var follow = true
    @State private var unseenBelow = false
    /// The prompt whose part of the conversation is on screen (marked in the rail).
    @State private var visiblePrompt: String?
    /// How many of the latest rows are drawn. A plain stack (not a lazy one) keeps every height exact — a lazy
    /// stack's guesses made the view jump, or show black and stop scrolling — so long sessions show their latest
    /// part and grow on request.
    @State private var shownCount = Self.page
    private static let page = 40

    private var conversation: some View {
        let items = transcript.items
        let prompts = items.compactMap { item -> PromptMark? in
            if case .prompt(let id, let text) = item { PromptMark(id: id, text: text) } else { nil }
        }
        var shownItems = items
        if let withdrawn, case .prompt(_, let text)? = shownItems.last, text == withdrawn { shownItems.removeLast() }
        let shown = shownItems.suffix(shownCount)
        let hidden = items.count - shown.count
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 10) {
                    if transcript.isLoaded && transcript.entries.isEmpty {
                        note("Nothing in this session yet.")
                    } else if !transcript.isLoaded {
                        note("Reading the session…")
                    }
                    if hidden > 0 {
                        Button {
                            let first = shown.first?.id
                            shownCount += Self.page
                            // Keep your place: the row that was first stays where it was.
                            if let first { Task { @MainActor in proxy.scrollTo(first, anchor: .top) } }
                        } label: {
                            Text("Show \(min(hidden, Self.page)) earlier")
                                .font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(Capsule().fill(.white.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)
                    }
                    ForEach(shown) { item in
                        // Equatable: a row redraws only when it changed, not on every update to the session.
                        SessionRow(item: item, highlighted: visiblePrompt == item.id && !follow, preview: previewFile)
                            .equatable()
                    }
                    if let liveReply {
                        Gutter(mark: "⏺", color: .white.opacity(0.85)) {
                            MarkdownView(text: liveReply)
                        }
                        .transition(.opacity)
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
                    Color.clear.frame(height: 1).id(Self.bottom)
                }
                .scrollTargetLayout()
                .padding(.leading, 12).padding(.trailing, prompts.count > 1 ? Self.railInset + 14 : 12).padding(.vertical, 10)
            }
            .defaultScrollAnchor(.bottom)
            .scrollContentBackground(.hidden)
            .modifier(FollowsBottom(follow: $follow, unseenBelow: $unseenBelow) { proxy.scrollTo(Self.bottom, anchor: .bottom) })
            .modifier(TracksVisiblePrompt { ids in
                visiblePrompt = PromptMark.current(visible: ids, in: items) ?? visiblePrompt
            })
            // A terminal's black, with the faint frame the notch's terminals have.
            .background(RoundedRectangle(cornerRadius: 10).fill(.black))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.1)))
            .overlay(alignment: .trailing) {
                if prompts.count > 1, claudePrompt == nil, claudeScreen == nil {
                    PromptRail(prompts: prompts, current: follow ? prompts.last?.id : visiblePrompt) { id in
                        follow = false
                        unseenBelow = false
                        visiblePrompt = id
                        // An older prompt than what's drawn: draw back to it first, then go there.
                        if let index = items.firstIndex(where: { $0.id == id }), items.count - index > shownCount {
                            shownCount = items.count - index
                        }
                        Task { @MainActor in
                            withAnimation(.smooth(duration: 0.3)) { proxy.scrollTo(id, anchor: .top) }
                        }
                    }
                    // Clear of the scroller, which shows along the very edge while scrolling.
                    .padding(.trailing, Self.railInset)
                }
            }
            .overlay(alignment: .bottom) {
                if unseenBelow && !follow {
                    Button {
                        follow = true
                        unseenBelow = false
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
            .onChange(of: transcript.entries.count) { _, _ in
                if follow {
                    toEnd(proxy)
                } else {
                    withAnimation(.easeOut(duration: 0.15)) { unseenBelow = true }
                }
            }
            .onChange(of: terminal.id) { _, _ in
                shownCount = Self.page
                follow = true
                unseenBelow = false
                visiblePrompt = nil
            }
            .onChange(of: approvals.count) { _, _ in
                follow = true
                toEnd(proxy)
            }
        }
    }

    /// To the end now, and again once the new rows are laid out (their heights are only known then).
    private func toEnd(_ proxy: ScrollViewProxy) {
        proxy.scrollTo(Self.bottom, anchor: .bottom)
        Task { @MainActor in
            for delay in [0, 60, 200] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard follow else { return }
                proxy.scrollTo(Self.bottom, anchor: .bottom)
            }
        }
    }

    private static let bottom = "bottom"
    private static let railInset: CGFloat = 13
    static let mono = Font.system(size: 11.5, design: .monospaced)

    /// A few times a second, reads Claude's attached terminal: whether its spinner is up (working or not), and the
    /// reply it's writing, until the session file has that reply. When the spinner and `claude agents` disagree,
    /// asks `claude agents` again so the overview catches up too.
    private func watchTerminal() async {
        screenBusy = nil
        liveReply = nil
        var sawSpinner = false
        var idleSince: Date?
        var spinnerGoneAt: Date?
        var seenOutput = -1
        var lastPass = Date.distantPast
        while !Task.isCancelled {
            // Re-read as soon as Claude redraws (a menu answering a key shows within a frame or two), else every
            // 0.4s for the clock-driven parts (the spinner going, the live text settling).
            try? await Task.sleep(for: .milliseconds(40))
            let output = terminal.claude.outputCount
            let since = Date().timeIntervalSince(lastPass)
            // A menu answers keys at once; otherwise streaming output is read at most ~7 times a second.
            guard (output != seenOutput && since >= (menuOpen ? 0 : 0.15)) || since >= 0.4 else { continue }
            seenOutput = output
            lastPass = Date()
            let lines = terminal.isRunning ? terminal.claude.screenLines : []
            let prompt = ClaudePrompt.parse(lines)
            if prompt != claudePrompt { withAnimation(.easeOut(duration: 0.15)) { claudePrompt = prompt } }
            let mode = ClaudeMode.parse(lines)
            if mode != claudeMode { claudeMode = mode }
            let cursor = terminal.claude.cursor
            let screen = prompt == nil ? ClaudeScreen.parse(lines, cursorLine: lines.indices.contains(cursor.row) ? lines[cursor.row] : nil) : nil
            if screen != claudeScreen { withAnimation(.easeOut(duration: 0.15)) { claudeScreen = screen } }
            let shells = ClaudeFooter.shells(lines)
            if shells != backgroundShells { backgroundShells = shells }
            let spinner = AgentTerminal.showsSpinner(lines)
            if spinner { sawSpinner = true }
            // Idle only after the spinner has been gone for a moment (it can blink between steps).
            spinnerGoneAt = spinner ? nil : (spinnerGoneAt ?? Date())
            let quiet = spinnerGoneAt.map { Date().timeIntervalSince($0) >= 1.2 } ?? false
            let busy: Bool? = terminal.isRunning && sawSpinner ? (spinner || !quiet) : nil
            if busy != screenBusy {
                screenBusy = busy
                if let busy, busy != agentBusy { Task { await app.agentMonitor?.refresh() } }
            }

            // What the session file already has, so the live text never repeats it (replies, the recap, notices).
            let recent = transcript.entries.suffix(16).compactMap { entry -> String? in
                switch entry.kind {
                case .reply(let text), .recap(let text), .notice(let text): text
                case .command(_, let output): output
                default: nil
                }
            }
            // After Esc: Claude puts an unanswered prompt back in its input box. Take it into the message box (and
            // out of Claude's, so it isn't sent twice).
            if let pressed = interruptedAt {
                if Date().timeIntervalSince(pressed) > 5 {
                    interruptedAt = nil
                } else if !spinner, let text = AgentTerminal.promptText(lines), !AgentTerminal.isPlaceholder(text) {
                    restore(text)
                    interruptedAt = nil
                }
            }
            var next: String?
            if isWorking, terminal.isRunning, let live = AgentTerminal.liveReply(terminal.claude.recentLines()) {
                next = AgentTerminal.reply(live, isIn: recent) ? nil : live
                idleSince = nil
            } else if let current = liveReply, !AgentTerminal.reply(current, isIn: recent) {
                // Finished: hold the text a moment until the reply reaches the session file, so it doesn't blink.
                idleSince = idleSince ?? Date()
                next = Date().timeIntervalSince(idleSince!) < 3 ? current : nil
            }
            if next != liveReply { liveReply = next }
        }
    }

    /// Esc while Claude works, from the message box or the Stop button.
    private func interrupt() {
        terminal.claude.view.send(data: [0x1B][...])
        interruptedAt = Date()
    }

    /// Your interrupted prompt, back in the message box (and out of Claude's input, so it isn't typed twice).
    private func restore(_ text: String) {
        withdrawn = text
        if draft.isEmpty { draft = text }
        terminal.claude.view.send(data: [0x15][...])  // ⌃U: clear Claude's input line
        composerFocused = true
    }

    private func previewFile(_ path: String) {
        guard let mention = FileMentions.resolve(path, in: terminal.agent.cwd) else { return }
        withAnimation(.easeOut(duration: 0.15)) { preview = FilePreview(mention: mention) }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).frame(maxWidth: .infinity)
    }

    // MARK: - Composer

    /// Claude Code's input box (a rule above and below) with the suggestions over it, then a slim footer of controls
    /// under it — the mode, background shells, Stop and the ⋯ menu — like the footer under Claude's own input. The
    /// controls never sit beside the text, so a long message isn't hidden behind them.
    private var composer: some View {
        VStack(spacing: 4) {
            VStack(spacing: 0) {
                if !images.isEmpty {
                    AttachmentStrip(images: images) { url in images.removeAll { $0 == url } }
                }
                composerLine
            }
            .overlay(alignment: .top) { Rectangle().fill(.white.opacity(composerFocused ? 0.3 : 0.15)).frame(height: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(composerFocused ? 0.3 : 0.15)).frame(height: 1) }
            composerFooter
        }
        .onChange(of: draft) { _, _ in refreshSuggestions() }
        .onChange(of: ProjectFiles.shared.files[terminal.agent.cwd]?.count) { _, _ in refreshSuggestions() }
    }

    private var composerLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("❯").font(Self.mono).foregroundStyle(.white.opacity(composerFocused ? 0.9 : 0.5))
            TextField(menuOpen ? "Keys go to Claude's menu — arrows, Return, Esc, or type to search"
                      : terminal.isRunning ? "Message \(terminal.agent.name)…" : "Detached — reattach to send",
                      text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Self.mono)
                .lineLimit(1...6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .focused($composerFocused)
                // While one of Claude's menus or prompts is open, every key goes to it, as in Claude's own terminal:
                // arrows, Return, Esc, Tab, a hint's letter, or typing into its search box.
                .onKeyPress(phases: .down) { press in
                    guard menuOpen, terminal.isRunning, let bytes = TerminalKeys.bytes(for: press) else { return .ignored }
                    terminal.claude.view.send(data: bytes[...])
                    return .handled
                }
                .disabled(!terminal.isRunning)
                .onSubmit(send)
                .onKeyPress(.leftArrow) {
                    guard !menuOpen else { return .ignored }
                    // ← in an empty box goes back, like ← from Claude's empty prompt.
                    guard draft.isEmpty else { return .ignored }
                    app.backToOverview()
                    return .handled
                }
                // ↑ / ↓ move through the suggestions when they're showing, else through your earlier prompts.
                .onKeyPress(.upArrow) {
                    guard !menuOpen else { return .ignored }
                    if !suggestions.isEmpty { suggestionIndex = max(0, suggestionIndex - 1); return .handled }
                    return stepHistory(back: true) ? .handled : .ignored
                }
                .onKeyPress(.downArrow) {
                    guard !menuOpen else { return .ignored }
                    if !suggestions.isEmpty { suggestionIndex = min(suggestions.count - 1, suggestionIndex + 1); return .handled }
                    return stepHistory(back: false) ? .handled : .ignored
                }
                // Tab takes a suggestion; Shift-Tab switches Claude's mode, as in its terminal.
                .onKeyPress(keys: [.tab]) { press in
                    guard !menuOpen else { return .ignored }
                    if press.modifiers.contains(.shift) {
                        guard terminal.isRunning else { return .ignored }
                        terminal.claude.view.send(data: ClaudeMode.cycleKey[...])
                        return .handled
                    }
                    guard suggestions.indices.contains(suggestionIndex) else { return .ignored }
                    take(suggestions[suggestionIndex])
                    return .handled
                }
                .onKeyPress(.return) {
                    guard !menuOpen else { return .ignored }
                    guard suggestions.indices.contains(suggestionIndex) else { return .ignored }
                    take(suggestions[suggestionIndex])
                    return .handled
                }
                .onKeyPress(.escape) {
                    guard !menuOpen else { return .ignored }
                    if !suggestions.isEmpty {
                        dismissedFor = draft
                        suggestions = []
                        return .handled
                    }
                    guard terminal.isRunning else { return .ignored }
                    // Esc while Claude works stops it, as in its terminal.
                    if isWorking {
                        interrupt()
                        return .handled
                    }
                    // Idle, Esc goes to Claude too: twice opens its rewind list, as in its terminal.
                    terminal.claude.view.send(data: [0x1B][...])
                    return .handled
                }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { composerFocused = true }
    }

    private var composerFooter: some View {
        HStack(spacing: 10) {
            if QuickCommands.shared.commands(for: terminal.agent.cwd).isEmpty && !addingQuickCommand {
                Button { withAnimation(.easeOut(duration: 0.15)) { addingQuickCommand = true } } label: {
                    Image(systemName: "bolt").font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.4))
                .help("Save a command you run often here (like make run) as a one-click button")
            }
            if terminal.isRunning {
                if isWorking {
                    Button { interrupt() } label: {
                        Label("Stop", systemImage: "stop.fill").font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.55))
                    .help("Interrupt Claude (Esc)")
                }
                if backgroundShells > 0 {
                    Button { openBackgroundTasks() } label: {
                        Label("\(backgroundShells) shell\(backgroundShells == 1 ? "" : "s")", systemImage: "terminal")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.6))
                    .help("Background shells Claude started — click to see or stop them")
                }
                Menu {
                    Button("Rewind…") { terminal.claude.view.send(data: ClaudePrompt.rewindKeys[...]) }
                        .disabled(isWorking)
                    Button("Background tasks") { openBackgroundTasks() }
                        .disabled(isWorking)
                    Divider()
                    Button("Compact conversation") { terminal.sendToClaude("/compact") }
                    Button("Show context usage") { terminal.sendToClaude("/context") }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(.white.opacity(0.5))
                .help("Rewind to an earlier prompt, background tasks, compact")
                if let claudeMode {
                    Button { terminal.claude.view.send(data: ClaudeMode.cycleKey[...]) } label: {
                        Text(claudeMode).font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.6))
                    .help("Claude Code's permission mode — click to switch (Shift-Tab)")
                }
                Spacer(minLength: 0)
                Text(draft.isEmpty && images.isEmpty ? "⌘V image · / commands · @ files" : "↩ send")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.3))
                    .lineLimit(1)
            } else {
                Spacer(minLength: 0)
                Button("Reattach") { app.reattach(terminal) }.controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 18)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !images.isEmpty, terminal.isRunning else { return }
        terminal.sendToClaude(ImageAttachments.message(text, images: images))
        draft = ""
        images = []
        historyIndex = nil
    }

    /// Recomputes the "/" and "@" suggestions for the draft (on each edit, not each redraw: there can be thousands
    /// of files to match).
    private func refreshSuggestions() {
        guard draft != dismissedFor else { suggestions = []; return }
        dismissedFor = nil
        let caret = ComposerSuggestions.caret(in: draft)
        let token = ComposerSuggestions.token(in: draft, caret: caret)
        let files = token?.kind == .file ? ProjectFiles.shared.files(in: terminal.agent.cwd) : []
        let next = ComposerSuggestions.suggestions(for: draft, caret: caret, folder: terminal.agent.cwd, files: files)
        if next != suggestions {
            suggestions = next
            suggestionIndex = 0
        }
    }

    /// Claude's background-task view: ↓ to its footer entry, then Return (one keystroke each, as typed).
    private func openBackgroundTasks() {
        let session = terminal.claude
        session.view.send(data: ClaudeFooter.manageKeys[0][...])
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            session.view.send(data: ClaudeFooter.manageKeys[1][...])
        }
    }

    private func take(_ suggestion: ComposerSuggestion) {
        draft = ComposerSuggestions.apply(suggestion, to: draft, caret: ComposerSuggestions.caret(in: draft))
        dismissedFor = draft
        suggestions = []
        composerFocused = true
    }

    /// Your earlier prompts, oldest first.
    private var promptHistory: [String] {
        transcript.items.compactMap { if case .prompt(_, let text) = $0 { text } else { nil } }
    }

    /// One step back or forward through your earlier prompts. Only from an empty box or while already stepping, so
    /// ↑ / ↓ still move between lines of a message you're writing.
    private func stepHistory(back: Bool) -> Bool {
        let history = promptHistory
        guard !history.isEmpty, draft.isEmpty || historyIndex != nil else { return false }
        // In a message of several lines, ↑ / ↓ move between its lines first; only from the first line (↑) or the
        // last (↓) do they go through your earlier prompts, as in Claude's terminal.
        if draft.contains("\n"), let caret = ComposerSuggestions.caret(in: draft) {
            if back, draft[..<caret].contains("\n") { return false }
            if !back, draft[caret...].contains("\n") { return false }
        }
        if back {
            if historyIndex == nil { draftBeforeHistory = draft }
            let next = max(0, (historyIndex ?? history.count) - 1)
            historyIndex = next
            draft = history[next]
        } else {
            guard let index = historyIndex else { return false }
            if index + 1 < history.count {
                historyIndex = index + 1
                draft = history[index + 1]
            } else {
                historyIndex = nil
                draft = draftBeforeHistory
            }
        }
        return true
    }
}

/// One of your prompts, as a mark in the rail beside the conversation.
struct PromptMark: Identifiable, Equatable {
    let id: String
    let text: String

    /// First line, collapsed whitespace — what the rail lists.
    var title: String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The prompt whose answer is on screen: the last prompt at or above the topmost visible row.
    static func current(visible ids: [String], in items: [SessionItem]) -> String? {
        let visible = Set(ids)
        guard let top = items.firstIndex(where: { visible.contains($0.id) }) else { return nil }
        for item in items[...top].reversed() {
            if case .prompt(let id, _) = item { return id }
        }
        return nil
    }
}

/// Your prompts down the side of the conversation: a quiet tick each, the one on screen brighter. Hover to read
/// them; click one to jump there.
private struct PromptRail: View {
    let prompts: [PromptMark]
    let current: String?
    let jump: (String) -> Void
    @State private var expanded = false

    var body: some View {
        ZStack(alignment: .trailing) {
            ticks.opacity(expanded ? 0 : 1)
            if expanded { list.transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .trailing))) }
        }
        .onHover { hovering in withAnimation(.easeOut(duration: 0.12)) { expanded = hovering } }
    }

    private var ticks: some View {
        VStack(alignment: .trailing, spacing: 5) {
            ForEach(prompts.suffix(18)) { prompt in
                Capsule()
                    .fill(.white.opacity(prompt.id == current ? 0.85 : 0.22))
                    .frame(width: prompt.id == current ? 12 : 7, height: 2)
            }
        }
        .padding(.vertical, 8).padding(.horizontal, 4)
        .contentShape(Rectangle())
    }

    private var list: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(prompts.enumerated()), id: \.element.id) { index, prompt in
                    PromptRailRow(number: index + 1, prompt: prompt, isCurrent: prompt.id == current) { jump(prompt.id) }
                }
            }
            .padding(4)
        }
        .defaultScrollAnchor(.bottom)
        .frame(width: 240)
        .frame(height: min(280, CGFloat(prompts.count) * 23 + 8))  // fits its rows, up to a point
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.11)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
    }
}

private struct PromptRailRow: View {
    let number: Int
    let prompt: PromptMark
    let isCurrent: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("\(number)").font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.white.opacity(0.3))
                    .frame(minWidth: 14, alignment: .trailing)
                Text(prompt.title).font(.system(size: 11)).lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(.white.opacity(isCurrent ? 1 : 0.75))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(isCurrent ? 0.12 : hovering ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(prompt.text.count > 60 ? String(prompt.text.prefix(400)) : "")
    }
}

/// Follows new rows while you're at the end and leaves you be once you scroll up (macOS 15's scroll geometry).
/// Never moves the view while you're scrolling it, and jumps at most once per update, so it can't fight you.
private struct FollowsBottom: ViewModifier {
    @Binding var follow: Bool
    @Binding var unseenBelow: Bool
    let scrollToBottom: () -> Void
    @State private var userScrolling = false
    @State private var pending = false

    struct Position: Equatable {
        var offset: CGFloat
        var height: CGFloat
        var visibleHeight: CGFloat
        var atEnd: Bool
    }

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content
                .onScrollPhaseChange { _, phase in
                    userScrolling = phase == .interacting || phase == .decelerating || phase == .tracking
                }
                .onScrollGeometryChange(for: Position.self) { geometry in
                    let bottom = geometry.contentOffset.y + geometry.containerSize.height
                    return Position(offset: geometry.contentOffset.y, height: geometry.contentSize.height,
                                    visibleHeight: geometry.containerSize.height,
                                    atEnd: bottom >= geometry.contentSize.height - 6)
                } action: { old, new in
                    // Any move up that the content didn't cause (it didn't shrink) is you — trackpad or mouse
                    // wheel, however little — and lets go of the end. The view only ever moves itself downward.
                    if new.offset < old.offset - 0.5, new.height >= old.height - 0.5 {
                        if follow { follow = false }
                        return
                    }
                    if new.atEnd {
                        if !follow { follow = true }  // back at the very end: follow again
                        if unseenBelow { unseenBelow = false }
                        return
                    }
                    // Taller content (a new row, a reply growing, a step finishing) or a shorter view (the message
                    // box growing) keeps the end in view — only while following.
                    let grew = new.height > old.height + 0.5 || new.visibleHeight < old.visibleHeight - 0.5
                    if follow, !userScrolling, grew { schedule() }
                }
        } else {
            content
        }
    }

    /// One jump to the end after this update settles, however many changes arrive in it.
    private func schedule() {
        guard !pending else { return }
        pending = true
        Task { @MainActor in
            pending = false
            if follow && !userScrolling { scrollToBottom() }
        }
    }
}

/// Reports which rows are on screen (macOS 15), for the rail's current prompt.
private struct TracksVisiblePrompt: ViewModifier {
    let update: ([String]) -> Void

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.onScrollTargetVisibilityChange(idType: String.self, threshold: 0.2) { ids in update(ids) }
        } else {
            content
        }
    }
}

/// One row of the conversation, laid out like Claude Code's own terminal: a marker in the gutter (❯ you, ⏺ Claude,
/// ⎿ its steps), everything left-aligned — but replies drawn as Markdown, so tables and lists read properly.
private struct SessionRow: View, Equatable {
    let item: SessionItem
    /// The prompt you jumped to from the rail.
    let highlighted: Bool
    let preview: (String) -> Void

    nonisolated static func == (lhs: SessionRow, rhs: SessionRow) -> Bool {
        lhs.item == rhs.item && lhs.highlighted == rhs.highlighted
    }

    var body: some View {
        switch item {
        case .prompt(_, let text):
            Gutter(mark: "❯", color: .white.opacity(0.55)) {
                Text(text)
                    .font(AgentSessionView.mono)
                    .foregroundStyle(.white.opacity(0.95))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 5)
            .background(Rectangle().fill(.white.opacity(highlighted ? 0.1 : 0.06)).padding(.leading, -12).padding(.trailing, -40))
            .padding(.top, 6)
        case .reply(_, let text):
            Gutter(mark: "⏺", color: .white.opacity(0.85)) {
                MarkdownView(text: text)
            }
        case .steps(_, let calls):
            Gutter(mark: "⎿", color: .white.opacity(0.3)) {
                ToolStepsRow(calls: calls, preview: preview)
            }
        case .recap(_, let text):
            Gutter(mark: "※", color: .white.opacity(0.35)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recap").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.white.opacity(0.4))
                        .textCase(.uppercase)
                    Text(text).font(.system(size: 11.5)).italic().foregroundStyle(.white.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
            .padding(.top, 6)
        case .notices(_, let texts):
            NoticesRow(texts: texts)
        case .command(_, let name, let output):
            CommandRow(name: name, output: output)
        }
    }
}

/// Claude Code's own notices (a hook or mod reloading) as one small line; click to list them.
private struct NoticesRow: View {
    let texts: [String]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(spacing: 5) {
                    Image(systemName: "info.circle").font(.system(size: 9))
                    Text(texts.count == 1 ? "1 notice from Claude Code" : "\(texts.count) notices from Claude Code")
                        .font(.system(size: 10))
                    Image(systemName: "chevron.right").font(.system(size: 7, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .foregroundStyle(.white.opacity(0.35))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                ForEach(Array(texts.enumerated()), id: \.offset) { _, text in
                    Text(text).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.white.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                .padding(.leading, 14)
            }
        }
        .padding(.leading, 20)
    }
}

/// A slash command you ran, like a prompt, with what it printed underneath (long output folds).
private struct CommandRow: View {
    let name: String
    let output: String?
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Gutter(mark: "❯", color: .white.opacity(0.55)) {
                Text(name).font(AgentSessionView.mono).foregroundStyle(Color(red: 1, green: 0.78, blue: 0.55))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let output {
                let lines = output.components(separatedBy: "\n")
                Gutter(mark: "⎿", color: .white.opacity(0.3)) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(expanded || lines.count <= 8 ? output : lines.prefix(8).joined(separator: "\n"))
                            .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.white.opacity(0.65))
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        if lines.count > 8 {
                            Button(expanded ? "Show less" : "Show all \(lines.count) lines") {
                                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
                            }
                            .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                        }
                    }
                }
            }
        }
        .padding(.top, 6)
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
enum SessionItem: Identifiable, Equatable {
    case prompt(id: String, String)
    case reply(id: String, String)
    case steps(id: String, [ToolCall])
    /// Claude Code's recap, above the prompt you came back with.
    case recap(id: String, String)
    /// Claude Code's own notices (hooks, mods reloading) in a row, as one quiet line.
    case notices(id: String, [String])
    /// A slash command and what it printed.
    case command(id: String, String, output: String?)

    var id: String {
        switch self {
        case .prompt(let id, _), .reply(let id, _), .steps(let id, _), .recap(let id, _), .notices(let id, _),
             .command(let id, _, _): id
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
            case .recap(let text): items.append(.recap(id: entry.id, text))
            case .notice(let text):
                if case .notices(let id, let texts)? = items.last {
                    items[items.count - 1] = .notices(id: id, texts + [text])
                } else {
                    items.append(.notices(id: entry.id, [text]))
                }
            case .command(let name, let output): items.append(.command(id: entry.id, name, output: output))
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
            .commandMenu(ranCommand)
            if expanded { detail.padding(.leading, 21) }
        }
        .padding(.horizontal, 4).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(expanded ? 0.06 : hovering ? 0.04 : 0)))
        .onHover { hovering = $0 }
    }

    /// The command a Bash step ran, for its right-click menu (run again, save as a quick command).
    private var ranCommand: String? {
        if case .command(let command) = call.detail { command } else { nil }
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
