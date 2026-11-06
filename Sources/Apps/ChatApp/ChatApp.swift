import AppKit
import SwiftUI
import WebKit
import NotchKit

/// Agents: one place for AI work. An Overview of Claude Code sessions (via `claude agents --json`) and the
/// web chats, plus ChatGPT, Claude and Muse themselves as their real websites (signed in with your own
/// accounts — usage is the same as using the sites in a browser; pages load the first time they're shown).
///
/// The module and app id stay "chat" so Ask menus and prompts from other apps keep routing here.
@MainActor @Observable
public final class ChatApp: NotchApp {
    public let id = "chat"
    public let name = "Agents"
    public let iconSystemName = "sparkles"
    public var expandedHeight: CGFloat { 460 }
    public var expandedWidth: CGFloat { 720 }

    var service: ChatService = .chatgpt {
        didSet { context?.defaults.set(service.rawValue, forKey: "service") }
    }
    /// The Overview tab is showing (instead of a chat).
    var showingOverview = true {
        didSet {
            context?.defaults.set(showingOverview, forKey: "showingOverview")
            if !showingOverview { context?.holdOpen(false) }
        }
    }
    /// The inline New Agent form is open on the Overview.
    var composingAgent = false
    /// The folder the New Agent form switches to, from a folder's or session's right-click New Agent Here.
    var newAgentFolder: String?
    /// Filters the Overview's sessions by name or project.
    var agentQuery = ""
    /// Show every finished session, not just the most recent few.
    var showAllCompleted = false
    /// The Overview lists sessions by project (a project's sessions together under it) instead of by status.
    var groupsAgentsByProject = true {
        didSet { context?.defaults.set(groupsAgentsByProject, forKey: "groupsAgentsByProject") }
    }
    /// Projects opened or folded by hand on the Overview, by folder; the rest follow `AgentProject.startsExpanded`.
    var projectExpansion: [String: Bool] = [:]
    /// The Overview's folders: one per project (made as projects appear) plus any you made.
    var agentFolders: [AgentFolder] = [] {
        didSet { context?.defaults.set(try? JSONEncoder().encode(agentFolders), forKey: "agentFolders") }
    }

    /// Claude Code sessions.
    @ObservationIgnored private(set) var agentMonitor: ClaudeAgentsMonitor!
    /// Claude Code token usage, from session transcripts.
    @ObservationIgnored let usageMonitor = ClaudeUsageMonitor()
    /// The usage breakdown is expanded on the Overview.
    var showUsageBreakdown = false

    func refreshUsage(force: Bool = false) async {
        let names = Dictionary((agentMonitor?.agents ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        async let tokens: () = usageMonitor.refresh(force: force) { names[$0] }
        async let limits: () = agentMonitor.refreshLimits(force: force)
        _ = await (tokens, limits)
    }
    /// Tool calls waiting for Allow / Deny (from the PermissionRequest hook), oldest first.
    private(set) var approvals: [ApprovalRequest] = []
    @ObservationIgnored private var approvalWaiters: [String: CheckedContinuation<ApprovalDecision, Never>] = [:]
    /// How long a request waits in the notch before Claude Code asks in its terminal instead.
    var approvalWait: Double = 60 {
        didSet { context?.defaults.set(approvalWait, forKey: "approvalWait") }
    }
    /// Ask in the notch for interactive sessions too (normally only background agents, whose terminal you're
    /// usually not looking at).
    var approvalsForAllSessions = false {
        didSet { context?.defaults.set(approvalsForAllSessions, forKey: "approvalsForAllSessions") }
    }
    private(set) var approvalHookInstalled = false
    private(set) var approvalHookError: String?

    /// When each agent last finished (this run of NotchMan), so Today can show what just completed.
    @ObservationIgnored private var finishedAt: [String: Date] = [:]
    /// Finished sessions stay on Today this long.
    static let recentlyFinished: TimeInterval = 2 * 3600

    /// Agents that needed you or finished while you weren't looking at the Overview.
    private(set) var unseenAgents: Set<String> = []
    var editor: AgentEditor = .vscode {
        didSet { context?.defaults.set(editor.rawValue, forKey: "editor") }
    }

    /// What clicking a background agent does.
    enum AgentOpenMode: String, CaseIterable, Identifiable {
        case notch, terminalApp
        var id: String { rawValue }
        var name: String { self == .notch ? "Terminal in the notch" : "New Terminal window" }
    }

    var agentOpenMode: AgentOpenMode = .notch {
        didSet { context?.defaults.set(agentOpenMode.rawValue, forKey: "agentOpenMode") }
    }

    /// In-notch terminals attached to background agents, by agent id; they keep running when hidden.
    private(set) var terminals: [String: AgentTerminal] = [:]
    /// The terminal shown on the Overview tab, if any.
    private(set) var shownTerminalID: String? {
        didSet { if shownTerminalID == nil { context?.holdOpen(false) } }
    }
    /// Terminals of your own, not an agent's (⌘T, or Terminal on the Overview).
    let shells = ShellWorkspace()
    /// The Overview tab shows those terminals instead of the list.
    private(set) var showingShells = false {
        didSet { if !showingShells { context?.holdOpen(false) } }
    }
    /// Where a new terminal starts when you don't pick a folder: the last one you used.
    var shellFolder = NSHomeDirectory() {
        didSet { context?.defaults.set(shellFolder, forKey: "shellFolder") }
    }
    private(set) var loading: Set<ChatService> = []
    /// Each service's current page (kept up to date as you navigate).
    private(set) var pageURLs: [ChatService: URL] = [:]
    /// Brief confirmation shown in the toolbar ("Link copied").
    private(set) var toast: String?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    /// Services currently generating a reply, and since when.
    private(set) var busySince: [ChatService: Date] = [:]
    /// Services with a finished reply the user hasn't looked at yet.
    private(set) var unread: Set<ChatService> = []
    /// Services moved out of the notch into their own window (for room, e.g. PDF previews).
    private(set) var poppedOut: Set<ChatService> = []
    @ObservationIgnored private var windows: [ChatService: NSWindow] = [:]
    @ObservationIgnored private var windowDelegates: [ChatService: WindowCloseObserver] = [:]
    /// Post a macOS notification when a reply finishes while you're not looking.
    var notifyWhenDone = true {
        didSet { context?.defaults.set(notifyWhenDone, forKey: "notifyWhenDone") }
    }

    /// Conversations on the chat sites for the Chats list, read from your accounts and remembered as you open them.
    private(set) var chatThreads: [ChatThread] = []
    /// Conversations kept at the top of the Chats list, by `ChatThread.id`.
    private(set) var pinnedChats: Set<String> = []
    /// The Chats list is showing in place of the chat page.
    var showingChatList = false
    /// The Chats list shows one service, or all of them (nil).
    var chatListFilter: ChatService? {
        didSet { context?.defaults.set(chatListFilter?.rawValue ?? "all", forKey: "chatListFilter") }
    }
    var chatListQuery = ""
    let chatListSelection = NotchListSelection()
    /// Services whose chat list is being read, and why the last read failed.
    private(set) var chatListLoading: Set<ChatService> = []
    private(set) var chatListErrors: [ChatService: String] = [:]
    @ObservationIgnored private var chatListReadAt: [ChatService: Date] = [:]

    /// Projects per service (for "Ask …" menus), and which one new asks go to by default.
    private(set) var projects: [ChatService: [AskProject]] = [:]
    private(set) var defaultProjects: [ChatService: String] = [:]

    /// Replies quicker than this don't notify.
    private static let notableReplyDuration: TimeInterval = 3

    @ObservationIgnored private var context: NotchContext?
    @ObservationIgnored private var webViews: [ChatService: WKWebView] = [:]
    @ObservationIgnored private let coordinator = ChatWebCoordinator()
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    /// Prompts waiting for their service's new-chat page to finish loading.
    @ObservationIgnored private var pendingPrompts: [ChatService: String] = [:]

    /// Desktop Safari's user agent: Google sign-in refuses embedded browsers that don't look like one.
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    public init() {}

    public func activate(context: NotchContext) {
        self.context = context
        coordinator.logger = context.logger
        coordinator.onFinish = { [weak self] view in self?.typePendingPrompt(into: view) }
        if let saved = context.defaults.string(forKey: "service").flatMap(ChatService.init(rawValue:)) {
            service = saved
        }
        notifyWhenDone = context.defaults.object(forKey: "notifyWhenDone") as? Bool ?? true
        showingOverview = context.defaults.object(forKey: "showingOverview") as? Bool ?? true
        agentFolders = Self.foldersWithPlacements(
            context.defaults.data(forKey: "agentFolders").flatMap { try? JSONDecoder().decode([AgentFolder].self, from: $0) } ?? [],
            context.defaults.dictionary(forKey: "agentPlacements") as? [String: String] ?? [:])
        context.defaults.removeObject(forKey: "agentPlacements")
        editor = context.defaults.string(forKey: "editor").flatMap(AgentEditor.init(rawValue:)) ?? .vscode
        agentOpenMode = context.defaults.string(forKey: "agentOpenMode").flatMap(AgentOpenMode.init(rawValue:)) ?? .notch
        groupsAgentsByProject = context.defaults.object(forKey: "groupsAgentsByProject") as? Bool ?? true
        shellFolder = context.defaults.string(forKey: "shellFolder") ?? NSHomeDirectory()
        shells.onClick = { [weak self] in self?.terminalClicked() }
        shells.onNewTab = { [weak self] in self?.openShell(in: self?.shells.selectedTab?.session.workingDirectory) }
        shells.onEmpty = { [weak self] in self?.showingShells = false }
        agentMonitor = ClaudeAgentsMonitor(defaults: context.defaults)
        agentMonitor.onEvents = { [weak self] events in self?.handle(events) }
        agentMonitor.onChange = { [weak self] in
            self?.syncFolders()
            self?.publishBoard()
        }
        NotchBoard.shared.insertIntoSession = { [weak self] project, text in
            self?.insert(text, intoSessionAt: project.cwd) ?? false
        }
        agentMonitor.start()
        approvalWait = context.defaults.object(forKey: "approvalWait") as? Double ?? 60
        approvalsForAllSessions = context.defaults.bool(forKey: "approvalsForAllSessions")
        approvalHookInstalled = ApprovalHook.isInstalled(in: ApprovalHook.readSettings())
        HookServer.shared.route("/permission") { [weak self] request in
            await self?.handlePermissionRequest(request.body) ?? .empty
        }
        for service in ChatService.allCases {
            if let data = context.defaults.data(forKey: "projects.\(service.rawValue)"),
               let saved = try? JSONDecoder().decode([AskProject].self, from: data) {
                // Older scans could keep icon glyphs in names (shown as "?" boxes).
                projects[service] = saved.map { AskProject(name: ChatService.cleanName($0.name), url: $0.url) }
            }
            defaultProjects[service] = context.defaults.string(forKey: "defaultProject.\(service.rawValue)")
        }
        if let data = context.defaults.data(forKey: "chatThreads"),
           let saved = try? JSONDecoder().decode([ChatThread].self, from: data) {
            chatThreads = saved
        }
        pinnedChats = Set(context.defaults.stringArray(forKey: "pinnedChats") ?? [])
        chatListFilter = context.defaults.string(forKey: "chatListFilter").flatMap(ChatService.init(rawValue:))
        AskAI.shared.promptTemplate = context.defaults.string(forKey: "askTemplate") ?? AskAI.defaultTemplate
        publishAskServices()
    }

    /// Created (and loaded) lazily, then kept for the app's lifetime so conversations survive collapsing.
    func webView(for service: ChatService) -> WKWebView {
        if let existing = webViews[service] { return existing }
        let config = WKWebViewConfiguration()
        // Persistent store: you stay signed in across launches.
        config.websiteDataStore = .default()
        config.preferences.isElementFullscreenEnabled = false
        if service.scrollsToLatest {
            ScrollMemory.install(in: config.userContentController, handler: ScrollMessageProxy { [weak self] path, spot in
                self?.scrollSpots[service, default: [:]][path] = spot
            })
        }
        ReplyWatcher.install(in: config.userContentController, handler: ReplyMessageProxy { [weak self] state in
            self?.replyStateChanged(service, state)
        })
        PageDiagnostics.install(in: config.userContentController, handler: DiagnosticsMessageProxy(logger: coordinator.logger))
        let view = NotchWebView(frame: .zero, configuration: config)
        // Safari → Develop → (this Mac) → NotchMan can inspect the chat page, for debugging site problems.
        view.isInspectable = true
        view.customUserAgent = Self.userAgent
        view.navigationDelegate = coordinator
        view.uiDelegate = coordinator
        view.allowsBackForwardNavigationGestures = true
        view.underPageBackgroundColor = .black
        observations.append(view.observe(\.url, options: [.new]) { [weak self] view, change in
            let url = change.newValue ?? nil
            Task { @MainActor in
                self?.pageURLs[service] = url
                // The title is still the last page's here; its own change names the conversation.
                self?.recordChat(service, url: url, title: "", opened: true)
            }
        })
        observations.append(view.observe(\.title, options: [.new]) { [weak self] view, change in
            let title = (change.newValue ?? nil) ?? ""
            Task { @MainActor in self?.recordChat(service, url: view.url, title: title, opened: false) }
        })
        observations.append(view.observe(\.isLoading, options: [.new]) { [weak self] _, change in
            let isLoading = change.newValue ?? false
            Task { @MainActor in
                if isLoading { self?.loading.insert(service) } else { self?.loading.remove(service) }
            }
        })
        view.load(URLRequest(url: service.home))
        webViews[service] = view
        return view
    }

    // MARK: - Prompts from other apps

    public func receive(_ message: NotchMessage) {
        if message.name == Self.openAgentMessage {
            showingOverview = true
            if let agent = agentMonitor.agents.first(where: { $0.id == message.payload["agent"] }) { open(agent) }
            return
        }
        if message.name == NotchMessage.notificationOpenedName {
            if let approval = message.payload["approval"] {
                switch message.payload["action"] {
                case "allow": resolveApproval(approval, .allow)
                case "deny": resolveApproval(approval, .deny)
                default: showingOverview = true
                }
                return
            }
            if let opened = message.payload["service"].flatMap(ChatService.init(rawValue:)) {
                show(opened)
            } else if message.payload["agent"] != nil {
                showingOverview = true
            }
            return
        }
        guard message.name == NotchMessage.chatPromptName, let text = message.payload["text"] else { return }
        let target = message.payload["service"].flatMap(ChatService.init(rawValue:)) ?? .chatgpt
        show(target)
        // Backup in case the site's message box can't be filled: just paste.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        pendingPrompts[target] = text
        // A page on the service's own site (e.g. a ChatGPT project) starts the chat there; else a new chat.
        let start = target.page(message.payload["url"]) ?? target.home
        let isNew = webViews[target] == nil
        let view = webView(for: target)  // creating it already loads the home (new chat) page
        if !isNew || start != target.home { view.load(URLRequest(url: start)) }
    }

    /// Types the prompt into the site's message box without sending it.
    private func typePendingPrompt(into view: WKWebView) {
        guard let service = webViews.first(where: { $0.value === view })?.key,
              let text = pendingPrompts.removeValue(forKey: service) else { return }
        Task {
            do {
                let filled = try await view.callAsyncJavaScript(
                    Self.fillComposerScript, arguments: ["text": text], in: nil, contentWorld: .defaultClient)
                if filled as? Bool != true {
                    context?.logger.notice("Couldn't find the message box; prompt is on the clipboard")
                }
            } catch {
                context?.logger.error("Prompt fill failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Waits for the chat composer (a ProseMirror editor on ChatGPT and Claude, or a textarea) and inserts
    /// `text` as if typed, so the site's editor state updates. Never presses send.
    private static let fillComposerScript = """
    const deadline = Date.now() + 15000;
    while (Date.now() < deadline) {
        const el = document.querySelector('#prompt-textarea')
            || document.querySelector('div.ProseMirror[contenteditable="true"]')
            || document.querySelector('[contenteditable="true"]')
            || document.querySelector('textarea');
        if (el) {
            el.focus();
            if (el.tagName === 'TEXTAREA') {
                const setter = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value').set;
                setter.call(el, text);
                el.dispatchEvent(new Event('input', { bubbles: true }));
            } else {
                document.execCommand('selectAll', false);
                document.execCommand('insertText', false, text);
            }
            return true;
        }
        await new Promise(r => setTimeout(r, 250));
    }
    return false;
    """

    // MARK: - Reply notifications

    private func replyStateChanged(_ service: ChatService, _ state: ReplyState) {
        context?.logger.notice("Reply \(service.rawValue, privacy: .public): \(state.busy ? "writing" : state.aborted ? "cancelled" : "done", privacy: .public) (\(state.via, privacy: .public))")
        let pageTitle = state.title
        if state.busy {
            busySince[service] = busySince[service] ?? Date()
            return
        }
        guard let started = busySince.removeValue(forKey: service), !state.aborted else { return }
        // A reply landed: the conversation moves to the top of the Chats list.
        if let view = webViews[service], let url = view.url, let conversation = service.conversation(at: url) {
            updateChats([ChatThread(service: service, conversationID: conversation.id, url: url.absoluteString,
                                    title: ChatService.chatTitle(fromPageTitle: view.title ?? ""), updated: Date())])
        }
        guard Date().timeIntervalSince(started) >= Self.notableReplyDuration, !isLooking(at: service) else { return }
        unread.insert(service)
        context?.requestAttention(.pulse)
        if notifyWhenDone {
            let title = pageTitle.replacingOccurrences(of: " - Claude", with: "").trimmingCharacters(in: .whitespaces)
            let generic = ["", "ChatGPT", "Claude", "muse.ai"].contains(title)
            context?.notify(title: "\(service.name) replied",
                            body: generic ? "Your response is ready." : title,
                            payload: ["service": service.rawValue])
        }
    }

    /// The chat is on screen: open in the notch on this service, or its own window is focused.
    private func isLooking(at service: ChatService) -> Bool {
        if windows[service]?.isKeyWindow == true { return true }
        return (context?.isVisible ?? false) && !showingOverview && !showingChatList && self.service == service
            && !poppedOut.contains(service)
    }

    private var isLookingAtOverview: Bool {
        (context?.isVisible ?? false) && showingOverview
    }

    /// Switches to a chat tab.
    func show(_ service: ChatService) {
        self.service = service
        showingOverview = false
        showingChatList = false
    }

    // MARK: - Chats list

    /// The Chats list's rows: the filter's service (or all), matching the search, pinned first then newest.
    var shownChats: [ChatThread] {
        ChatThreads.grouped(chatThreads.filter { (chatListFilter == nil || $0.service == chatListFilter)
            && ChatThreads.matches($0, query: chatListQuery) }, pinned: pinnedChats).flatMap(\.threads)
    }

    func toggleChatList() {
        if showingChatList {
            showingChatList = false
            return
        }
        chatListQuery = ""
        chatListSelection.index = nil
        showingChatList = true
        Task { await refreshChats() }
    }

    /// Opens a conversation in its service's tab (or its own window, if that service is popped out).
    func open(_ thread: ChatThread) {
        show(thread.service)
        guard let url = URL(string: thread.url) else { return }
        let view = webView(for: thread.service)
        if view.url.flatMap({ thread.service.conversation(at: $0)?.id }) != thread.conversationID {
            view.load(URLRequest(url: url))
        }
        if poppedOut.contains(thread.service) { showWindow() }
    }

    /// The conversation on screen in `service`'s tab right now, if it's one.
    func isCurrent(_ thread: ChatThread) -> Bool {
        pageURLs[thread.service].flatMap { thread.service.conversation(at: $0)?.id } == thread.conversationID
    }

    /// Reads each service's chat list from your account, one at a time (each loads the site in a hidden page).
    /// Skips services read in the last couple of minutes unless `force`.
    func refreshChats(force: Bool = false) async {
        let services = chatListFilter.map { [$0] } ?? ChatService.allCases
        for service in services where !chatListLoading.contains(service) {
            if !force, let last = chatListReadAt[service], Date().timeIntervalSince(last) < 120 { continue }
            await readChats(service, full: false)
        }
    }

    /// A full sync is running (the Sync button).
    private(set) var chatListSyncing = false
    /// What the last full sync found, for the list's footer.
    private(set) var chatListSyncSummary: String?

    /// Reads every chat of the filter's services (or all), not just the newest, and drops ones deleted on the
    /// site. Slower than the automatic refresh: it pages through each site's whole list.
    func syncAllChats() async {
        guard !chatListSyncing else { return }
        chatListSyncing = true
        chatListSyncSummary = nil
        let services = chatListFilter.map { [$0] } ?? ChatService.allCases
        var counts: [String] = []
        for service in services {
            // Let a quick refresh of this service finish first.
            while chatListLoading.contains(service) { try? await Task.sleep(for: .milliseconds(200)) }
            if let count = await readChats(service, full: true) { counts.append("\(count) \(service.name)") }
        }
        chatListSyncing = false
        let time = Date().formatted(date: .omitted, time: .shortened)
        chatListSyncSummary = counts.isEmpty ? nil : "Synced \(counts.joined(separator: ", ")) chats at \(time)."
    }

    /// Reads one service's chat list and adds it to the list; returns how many chats it found, or nil if it
    /// couldn't be read.
    @discardableResult
    private func readChats(_ service: ChatService, full: Bool) async -> Int? {
        chatListLoading.insert(service)
        chatListReadAt[service] = Date()
        defer { chatListLoading.remove(service) }
        let names = Dictionary((projects[service] ?? []).compactMap { project -> (String, String)? in
            guard let id = project.url.firstMatch(of: /\/g\/(g-p-[A-Za-z0-9]+)/).map({ String($0.1) }) else { return nil }
            return (id, project.name)
        }, uniquingKeysWith: { a, _ in a })
        do {
            let result = try await ChatListScraper(service: service, userAgent: Self.userAgent, projectNames: names)
                .run(full: full, timeout: full ? 60 : 15)
            context?.logger.notice("Chat list \(service.rawValue, privacy: .public)\(full ? " (full)" : "", privacy: .public): \(result.threads.count, privacy: .public) chats, complete: \(result.complete, privacy: .public)")
            chatListErrors[service] = nil
            if result.complete {
                chatThreads = ChatThreads.trimmed(
                    ChatThreads.replacing(chatThreads, with: result.threads, for: service, pinned: pinnedChats),
                    pinned: pinnedChats)
                saveChats()
            } else {
                updateChats(result.threads)
            }
            return result.threads.count
        } catch {
            chatListErrors[service] = error.localizedDescription
            return nil
        }
    }

    func useChatsForTesting(_ threads: [ChatThread], pinned: Set<String> = []) {
        chatThreads = threads
        pinnedChats = pinned
    }

    func togglePin(_ thread: ChatThread) {
        if pinnedChats.remove(thread.id) == nil { pinnedChats.insert(thread.id) }
        context?.defaults.set(Array(pinnedChats), forKey: "pinnedChats")
    }

    /// Takes a conversation off the list (it comes back if the site still lists it or you open it again).
    func removeFromList(_ thread: ChatThread) {
        chatThreads.removeAll { $0.id == thread.id }
        pinnedChats.remove(thread.id)
        context?.defaults.set(Array(pinnedChats), forKey: "pinnedChats")
        saveChats()
    }

    func copyLink(_ thread: ChatThread) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(thread.url, forType: .string)
    }

    /// The notch's page moved to (or renamed) a conversation: remember it, as just opened when `opened`.
    private func recordChat(_ service: ChatService, url: URL?, title: String, opened: Bool) {
        guard let url, let conversation = service.conversation(at: url) else { return }
        let thread = ChatThread(service: service, conversationID: conversation.id, url: url.absoluteString,
                                title: ChatService.chatTitle(fromPageTitle: title), opened: opened ? Date() : nil)
        // Renames of a conversation we don't know yet wait for it to be opened.
        guard opened || chatThreads.contains(where: { $0.id == thread.id }) else { return }
        updateChats([thread])
    }

    private func updateChats(_ fresh: [ChatThread]) {
        let merged = ChatThreads.merge(chatThreads, fresh)
        guard merged != chatThreads else { return }
        chatThreads = ChatThreads.trimmed(merged, pinned: pinnedChats)
        saveChats()
    }

    private func saveChats() {
        context?.defaults.set(try? JSONEncoder().encode(chatThreads), forKey: "chatThreads")
    }

    // MARK: - Claude Code agents

    /// Sent to ourselves (so the engine brings the Agents app up) to open an agent from the Today app.
    static let openAgentMessage = "agents.open"

    /// Active sessions' folders (for the Shelf's project drop) and agents that need you (for Today).
    func publishBoard() {
        let active = agentMonitor.agents.filter { $0.phase != .done }
        var seen = Set<String>()
        // Background agents first, so a folder with both offers typing into the notch terminal.
        let projects = active.sorted { ($0.kind == .background ? 0 : 1) < ($1.kind == .background ? 0 : 1) }
            .filter { seen.insert($0.cwd).inserted }
            .map { BoardProject(name: $0.name, cwd: $0.cwd, agentID: $0.shortID) }
        NotchBoard.shared.publishProjects(projects)

        func openAction(_ agent: ClaudeAgent) -> BoardAction {
            BoardAction("Open", systemImage: "terminal") { [weak self] in
                self?.context?.send(NotchMessage(name: Self.openAgentMessage, payload: ["agent": agent.id]), to: "chat")
            }
        }
        let agents = agentMonitor.agents
        let needsYou = agents.filter { $0.phase == .needsYou }.map { agent in
            BoardItem(id: "agent:\(agent.id)", kind: .agent, title: agent.name,
                      subtitle: agent.project, tint: .orange, primary: openAction(agent))
        }
        let working = agents.filter { $0.phase == .working }.map { agent in
            BoardItem(id: "session:\(agent.id)", kind: .session, title: agent.name, subtitle: agent.project,
                      date: agent.startedAt, isWorking: true, open: openAction(agent))
        }
        // Just finished: in the last couple of hours, or not yet looked at.
        let now = Date()
        let finished = agents.filter { $0.phase == .done || $0.phase == .idle }.compactMap { agent -> BoardItem? in
            let when = finishedAt[agent.id]
            let recent = when.map { now.timeIntervalSince($0) < Self.recentlyFinished } ?? false
            guard recent || (agent.phase == .done && unseenAgents.contains(agent.id)) else { return nil }
            return BoardItem(id: "session:\(agent.id)", kind: .session, title: agent.name, subtitle: agent.project,
                             date: when, tint: .green, open: openAction(agent))
        }
        .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        NotchBoard.shared.publish(needsYou + approvalBoardItems + working + finished, from: id)
    }

    /// Types `text` into the Claude terminal of the open notch workspace for `cwd`, without pressing Return.
    func insert(_ text: String, intoSessionAt cwd: String) -> Bool {
        guard let terminal = terminals.values.first(where: { $0.agent.cwd == cwd && $0.isRunning }) else { return false }
        terminal.view.send(txt: text)
        return true
    }

    // MARK: - Approvals

    /// A PermissionRequest hook call: show it, wait for Allow / Deny (or the wait to run out), and answer.
    func handlePermissionRequest(_ body: Data) async -> HookServer.Response {
        guard let request = ApprovalRequest.decode(body) else { return .empty }
        let agent = agentMonitor.agents.first { $0.id == request.sessionID }
        // Only sessions we know are background agents, unless asked otherwise; the rest ask in their terminal.
        guard approvalsForAllSessions || agent?.kind == .background else { return .empty }

        approvals.append(request)
        publishBoard()
        let who = agent?.name ?? request.project
        context?.notify(title: "\(who) wants to use \(request.toolName)",
                        body: (request.risk.map { "⚠ \($0) · " } ?? "") + request.summary,
                        payload: ["approval": request.id],
                        actions: [NotchNotificationAction(id: "allow", title: "Allow"),
                                  NotchNotificationAction(id: "deny", title: "Deny", isDestructive: true)])
        context?.requestAttention(.pulse)

        let wait = approvalWait
        let decision = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                approvalWaiters[request.id] = continuation
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(wait))
                    self?.resolveApproval(request.id, .terminal)
                }
            }
        } onCancel: {
            // Claude Code hung up (interrupted, or its hook timeout passed).
            Task { @MainActor [weak self] in self?.resolveApproval(request.id, .terminal) }
        }
        return ApprovalHook.output(decision).map(HookServer.Response.json) ?? .empty
    }

    func resolveApproval(_ id: String, _ decision: ApprovalDecision) {
        approvals.removeAll { $0.id == id }
        approvalWaiters.removeValue(forKey: id)?.resume(returning: decision)
        publishBoard()
    }

    /// Adds (or removes) NotchMan's hook in ~/.claude/settings.json, keeping a backup of the file.
    func setApprovalHookInstalled(_ install: Bool) {
        do {
            let settings = ApprovalHook.readSettings()
            // Claude Code's hook timeout sits a little past ours, so NotchMan always answers first.
            let updated = install
                ? ApprovalHook.installing(into: settings, token: HookServer.shared.token, timeout: Int(approvalWait) + 10)
                : ApprovalHook.removing(from: settings)
            try ApprovalHook.writeSettings(updated)
            approvalHookInstalled = install
            approvalHookError = nil
        } catch {
            approvalHookError = error.localizedDescription
        }
    }

    /// Re-writes the hook so its timeout follows a changed wait.
    func approvalWaitChanged() {
        if approvalHookInstalled { setApprovalHookInstalled(true) }
    }

    /// Pending approvals for the Today app, with Allow / Deny in place.
    var approvalBoardItems: [BoardItem] {
        approvals.map { request in
            BoardItem(id: "approval:\(request.id)", kind: .approval, title: "\(request.toolName): \(request.summary)",
                      subtitle: (request.risk.map { "⚠ \($0) · " } ?? "") + request.project,
                      tint: request.risk == nil ? .orange : .red,
                      primary: BoardAction("Allow", systemImage: "checkmark") { [weak self] in
                          self?.resolveApproval(request.id, .allow)
                      },
                      secondary: BoardAction("Deny", systemImage: "xmark") { [weak self] in
                          self?.resolveApproval(request.id, .deny)
                      })
        }
    }

    private func handle(_ events: [AgentEvent]) {
        for case .finished(let agent) in events { finishedAt[agent.id] = Date() }
        publishBoard()
        guard !isLookingAtOverview else { return }
        for event in events {
            unseenAgents.insert(event.agent.id)
            guard notifyWhenDone else { continue }
            let agent = event.agent
            switch event {
            case .needsYou:
                context?.notify(title: "\(agent.name) needs you", body: "Claude Code · \(agent.project)", payload: ["agent": agent.id])
            case .finished:
                context?.notify(title: "\(agent.name) finished", body: "Claude Code · \(agent.project)", payload: ["agent": agent.id])
            }
        }
        context?.requestAttention(.pulse)
    }

    /// For tests.
    func useUnseenForTesting(_ ids: Set<String>) {
        unseenAgents = ids
    }

    /// For tests: use a monitor without starting it.
    func useAgentMonitor(_ monitor: ClaudeAgentsMonitor) {
        agentMonitor = monitor
    }

    func markOverviewSeen() {
        unseenAgents.removeAll()
        publishBoard()
    }

    /// Background agents open attached in a terminal (in the notch or Terminal, per settings); interactive
    /// ones open their folder in the editor.
    func open(_ agent: ClaudeAgent) {
        guard agent.kind == .background else {
            editor.open(agent.cwd)
            return
        }
        switch agentOpenMode {
        case .notch: openInNotch(agent)
        case .terminalApp: openInTerminalApp(agent)
        }
    }

    // MARK: - In-notch terminals

    var shownTerminal: AgentTerminal? {
        shownTerminalID.flatMap { terminals[$0] }
    }

    func openInNotch(_ agent: ClaudeAgent) {
        let terminal = terminals[agent.id] ?? AgentTerminal(agent: agent)
        terminals[agent.id] = terminal
        // ← out of the session goes to NotchMan's Overview, not Claude Code's own agent list.
        terminal.onAgentList = { [weak self] in self?.closeTerminal(agent.id) }
        terminal.onClick = { [weak self] in self?.terminalClicked() }
        terminal.update(agent)
        showingOverview = true
        showingShells = false
        shownTerminalID = agent.id
        if !terminal.isRunning { reattach(terminal) }
    }

    func reattach(_ terminal: AgentTerminal) {
        Task {
            guard let path = await agentMonitor.claudePath() else { return }
            terminal.start(claudePath: path)
        }
    }

    /// Detaches the in-notch terminal (if any) and attaches in a new Terminal window instead.
    func openInTerminalApp(_ agent: ClaudeAgent) {
        if terminals[agent.id] != nil { closeTerminal(agent.id) }
        Task { await agentMonitor.attach(agent) }
    }

    /// Stops a background session (its conversation is kept).
    func stopSession(_ agent: ClaudeAgent) {
        if terminals[agent.id] != nil { closeTerminal(agent.id) }
        Task {
            do { try await agentMonitor.stop(agent) } catch { Self.showFailure("Couldn't stop “\(agent.name)”", error) }
        }
    }

    /// Deletes a background session after confirming; it can't be undone.
    func deleteSession(_ agent: ClaudeAgent) {
        let alert = NSAlert()
        alert.messageText = "Delete “\(agent.name)”?"
        alert.informativeText = """
            This removes the session and its conversation from Claude Code (and its worktree when that's safe). \
            It can't be undone. To keep the conversation, use Stop Session instead.
            """
        alert.alertStyle = .warning
        let delete = alert.addButton(withTitle: "Delete")
        delete.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        if terminals[agent.id] != nil { closeTerminal(agent.id) }
        unseenAgents.remove(agent.id)
        Task {
            do { try await agentMonitor.delete(agent) } catch { Self.showFailure("Couldn't delete “\(agent.name)”", error) }
        }
    }

    // MARK: - Folders

    /// The folder you moved `sessionID` into by hand, if any.
    func folder(of sessionID: String) -> AgentFolder? {
        agentFolders.first { $0.sessions.contains(sessionID) }
    }

    /// The folder `agent` shows in: where you moved it, else its project's.
    func listedFolder(of agent: ClaudeAgent) -> AgentFolder? {
        folder(of: agent.id) ?? agentFolders.first { $0.projects.contains(ClaudeAgentsMonitor.projectFolder(agent.cwd)) }
    }

    /// The folders on the Overview, to move sessions into, by name.
    var shownFolders: [AgentFolder] {
        AgentProject.group(agentMonitor?.agents ?? [], folders: agentFolders).map(\.folder)
            .filter { folder in agentFolders.contains { $0.id == folder.id } }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Makes a folder for each project that has sessions but no folder yet (also after you delete one), and
    /// forgets sessions that no longer exist.
    func syncFolders() {
        guard let monitor = agentMonitor, monitor.hasLoaded else { return }
        var folders = agentFolders
        let known = Set(monitor.agents.map(\.id))
        for index in folders.indices where folders[index].sessions.contains(where: { !known.contains($0) }) {
            folders[index].sessions.removeAll { !known.contains($0) }
        }
        folders += AgentProject.missingProjects(monitor.agents, folders: folders).map(AgentFolder.forProject)
        if folders != agentFolders { agentFolders = folders }
    }

    /// Before there was one kind of folder, sessions could be moved under another project (session → project path);
    /// those become sessions moved into that project's folder.
    static func foldersWithPlacements(_ folders: [AgentFolder], _ placements: [String: String]) -> [AgentFolder] {
        var folders = folders
        for (session, path) in placements.sorted(by: { $0.key < $1.key }) where !folders.contains(where: { $0.sessions.contains(session) }) {
            if let index = folders.firstIndex(where: { $0.projects.contains(path) }) {
                folders[index].sessions.append(session)
            } else {
                var folder = AgentFolder.forProject(path)
                folder.sessions = [session]
                folders.append(folder)
            }
        }
        return folders
    }

    /// Asks for a name and makes a new folder (opened), putting `sessions` in it. Returns its ID.
    @discardableResult
    func newFolder(with sessions: [String] = []) -> UUID? {
        guard let name = Self.askFolderName(title: "New Folder", initial: "") else { return nil }
        let folder = AgentFolder(name: name)
        agentFolders.append(folder)
        move(sessions, to: folder.id)
        projectExpansion["folder:\(folder.id)"] = true
        return folder.id
    }

    /// Puts sessions in a folder (out of any other), or back in their project's folder when `folderID` is nil or
    /// is that folder.
    func move(_ sessions: [String], to folderID: UUID?) {
        let agents = agentMonitor?.agents ?? []
        var folders = agentFolders
        for index in folders.indices {
            folders[index].sessions.removeAll { sessions.contains($0) }
            guard folders[index].id == folderID else { continue }
            folders[index].sessions += sessions.filter { id in
                // Its own project's folder takes it anyway.
                guard let agent = agents.first(where: { $0.id == id }) else { return true }
                return !folders[index].projects.contains(ClaudeAgentsMonitor.projectFolder(agent.cwd))
            }
        }
        agentFolders = folders
        syncFolders()
    }

    func renameFolder(_ id: UUID) {
        guard let index = agentFolders.firstIndex(where: { $0.id == id }),
              let name = Self.askFolderName(title: "Rename Folder", initial: agentFolders[index].name) else { return }
        agentFolders[index].name = name
    }

    /// Removes the folder; its sessions go back to their projects' folders (made afresh where needed, even for the
    /// project this folder collected).
    func deleteFolder(_ id: UUID) {
        agentFolders.removeAll { $0.id == id }
        projectExpansion["folder:\(id)"] = nil
        syncFolders()
    }

    private static func askFolderName(title: String, initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Sessions you move into a folder show there instead of in their project's folder."
        let field = NSTextField(string: initial)
        field.placeholderString = "Folder name"
        field.frame = CGRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: initial.isEmpty ? "Create" : "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private static func showFailure(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        NSApp.activate()
        alert.runModal()
    }

    /// Ends the in-notch attach; the agent keeps running.
    func closeTerminal(_ id: String) {
        terminals.removeValue(forKey: id)?.stop()
        if shownTerminalID == id { shownTerminalID = nil }
    }

    /// Back to the agent list; the terminal keeps running and can be reopened from its row (or Terminal's pill).
    func backToOverview() {
        shownTerminalID = nil
        showingShells = false
    }

    /// Shows your own terminals with the keyboard in one: a new terminal in `folder` when given (or, when there are
    /// none yet, in the last folder you used), else the one you were on.
    func openShell(in folder: String? = nil) {
        if folder != nil || shells.tabs.isEmpty {
            let start = folder ?? shellFolder
            shells.add(in: FileManager.default.fileExists(atPath: start) ? start : NSHomeDirectory())
        }
        if let folder { shellFolder = folder }
        showingOverview = true
        shownTerminalID = nil
        showingShells = true
        // You opened it to type: keep the notch open until a click outside, as clicking into a terminal does.
        terminalClicked()
        shells.selectedTab?.session.focusWhenShown()
    }

    /// Opens the New Agent form (or keeps it open) with `folder` picked, so only the prompt is left to type.
    func composeAgent(in folder: String) {
        newAgentFolder = folder
        composingAgent = true
    }

    /// ⌘T opens a terminal in the notch.
    public func handleKey(_ event: NSEvent) -> Bool {
        if showingChatList {
            if event.keyCode == 53 {  // Esc: back to the chat
                showingChatList = false
                return true
            }
            let shown = shownChats
            if chatListSelection.handle(event, count: shown.count, open: { self.open(shown[$0]) }) { return true }
        }
        guard event.modifierFlags.intersection([.command, .option, .shift, .control]) == .command,
              event.charactersIgnoringModifiers?.lowercased() == "t" else { return false }
        openShell()
        return true
    }

    /// Clicking into a terminal keeps the notch open while the mouse wanders (so typing isn't cut off) until a
    /// click outside closes it. Just opening a terminal doesn't: moving away still closes the notch.
    func terminalClicked() {
        context?.holdOpen(true)
    }

    /// Called by the view when a service is on screen.
    func markSeen(_ service: ChatService) {
        unread.remove(service)
    }

    func isBusy(_ service: ChatService) -> Bool { busySince[service] != nil }

    /// One summary of all AI activity, most urgent first.
    struct Summary: Equatable {
        enum Kind: Equatable { case needsYou, working, ready }
        let kind: Kind
        let label: String
    }

    /// Needs you (agents that newly need input) > working (busy agents + writing chats) > ready (finished
    /// agents and chat replies you haven't seen). A single chat shows its name instead of a count.
    static func summary(needsYou: Int, workingAgents: Int, writingChats: [ChatService],
                        readyAgents: Int, readyChats: [ChatService]) -> Summary? {
        if needsYou > 0 {
            return Summary(kind: .needsYou, label: needsYou == 1 ? "1 needs you" : "\(needsYou) need you")
        }
        let working = workingAgents + writingChats.count
        if working > 0 {
            let label = working == 1 && writingChats.count == 1 ? writingChats[0].shortName : "\(working) working"
            return Summary(kind: .working, label: label)
        }
        let ready = readyAgents + readyChats.count
        if ready > 0 {
            let label = ready == 1 && readyChats.count == 1 ? readyChats[0].shortName : "\(ready) ready"
            return Summary(kind: .ready, label: label)
        }
        return nil
    }

    private var currentSummary: Summary? {
        let agents = agentMonitor?.agents ?? []
        let unseen = agents.filter { unseenAgents.contains($0.id) }
        return Self.summary(
            needsYou: unseen.filter { $0.phase == .needsYou }.count,
            workingAgents: agents.filter { $0.phase == .working }.count,
            writingChats: ChatService.allCases.filter(isBusy),
            readyAgents: unseen.filter { $0.phase == .done || $0.phase == .idle }.count,
            readyChats: ChatService.allCases.filter { unread.contains($0) && !isBusy($0) }
        )
    }

    /// Collapsed-notch chip for all AI activity; outranks music so it isn't hidden while something plays.
    public var activity: NotchActivity? {
        if let first = approvals.first {
            let label = approvals.count == 1 ? "Allow \(first.toolName)?" : "\(approvals.count) to allow"
            return NotchActivity(priority: 25) {
                NotchChip(label, systemImage: "hand.raised.fill", tint: first.risk == nil ? .orange : .red)
            }
        }
        guard let summary = currentSummary else { return nil }
        switch summary.kind {
        case .needsYou:
            return NotchActivity(priority: 18) {
                NotchChip(summary.label, systemImage: "exclamationmark.bubble.fill", tint: .orange)
            }
        case .working:
            return NotchActivity(priority: 14) {
                NotchChip(summary.label) { NotchSpinner(size: 11, lineWidth: 1.8) }
            }
        case .ready:
            return NotchActivity(priority: 12) {
                NotchChip(summary.label, systemImage: "checkmark.circle.fill", tint: .green)
            }
        }
    }

    public var dockBadge: NotchBadge? {
        if !approvals.isEmpty { return .dot(.orange) }
        return switch currentSummary?.kind {
        case .needsYou: .dot(.orange)
        case .working: .busy
        case .ready: .dot(.green)
        case nil: nil
        }
    }

    public func makeSettingsView() -> AnyView? {
        AnyView(ChatSettingsView(app: self))
    }

    // MARK: - Projects / Ask from anywhere

    var askTemplate: String {
        get { AskAI.shared.promptTemplate }
        set {
            AskAI.shared.promptTemplate = newValue
            context?.defaults.set(newValue, forKey: "askTemplate")
        }
    }

    func setProjects(_ list: [AskProject], for service: ChatService) {
        projects[service] = list
        if let data = try? JSONEncoder().encode(list) { context?.defaults.set(data, forKey: "projects.\(service.rawValue)") }
        if let current = defaultProjects[service], !list.contains(where: { $0.url == current }) {
            setDefaultProject(nil, for: service)
        }
        publishAskServices()
    }

    func setDefaultProject(_ url: String?, for service: ChatService) {
        defaultProjects[service] = url
        context?.defaults.set(url, forKey: "defaultProject.\(service.rawValue)")
        publishAskServices()
    }

    private func publishAskServices() {
        AskAI.shared.services = ChatService.allCases.map {
            AskService(id: $0.rawValue, name: $0.name, projects: projects[$0] ?? [], defaultProjectURL: defaultProjects[$0])
        }
    }

    /// Reads the project links from the service's signed-in page (its sidebar) and merges them in.
    /// Returns how many new projects were found.
    /// Reads the project list from a hidden desktop-width copy of the site and merges new ones in.
    func loadProjects(for service: ChatService) async throws -> ProjectLoadResult {
        let result = try await ProjectScraper(service: service, userAgent: Self.userAgent).run()
        context?.logger.notice("Project scan \(service.rawValue, privacy: .public): \(result.projects.count, privacy: .public) projects among \(result.linksSeen, privacy: .public) links")
        if result.projects.isEmpty, !result.candidatePaths.isEmpty {
            context?.logger.notice("Project-like links seen: \(result.candidatePaths.joined(separator: " "), privacy: .public)")
        }
        var merged = projects[service] ?? []
        let new = result.projects.filter { project in !merged.contains { $0.url == project.url } }
        merged += new
        setProjects(merged, for: service)
        return ProjectLoadResult(added: new.count, found: result.projects.count, linksSeen: result.linksSeen)
    }

    struct ProjectLoadResult {
        let added: Int
        let found: Int
        let linksSeen: Int

        var message: String {
            if added > 0 { return "Added \(added) project\(added == 1 ? "" : "s")." }
            if found > 0 { return "All \(found) projects are already listed." }
            if linksSeen == 0 { return "The page didn't load. Check you're signed in, then try again." }
            return "No projects found (looked at \(linksSeen) links). If you have projects, add one by pasting its link."
        }
    }

    // MARK: - Pop out

    /// Moves the current chat (conversation and all) into a normal resizable window.
    func popOut() {
        let service = self.service
        if let existing = windows[service] {
            NSApp.activate()
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let view = webView(for: service)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 900)
        let size = CGSize(width: min(1100, visible.width - 80), height: min(900, visible.height - 80))
        let window = NSWindow(
            contentRect: CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                                width: size.width, height: size.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = service.name
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("NotchManChat-\(service.rawValue)")

        let container = NSView()
        window.contentView = container
        view.removeFromSuperview()
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)

        let observer = WindowCloseObserver { [weak self] in self?.windowClosed(service) }
        window.delegate = observer
        windowDelegates[service] = observer
        windows[service] = window
        poppedOut.insert(service)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Closes the window; the chat goes back into the notch.
    func bringBack() {
        windows[service]?.close()
    }

    func showWindow() {
        NSApp.activate()
        windows[service]?.makeKeyAndOrderFront(nil)
    }

    private func windowClosed(_ service: ChatService) {
        windows[service] = nil
        windowDelegates[service] = nil
        poppedOut.remove(service)
    }

    // MARK: - Scroll position

    /// Where you were in each conversation, by service and page path (reported by the page as you scroll).
    @ObservationIgnored private var scrollSpots: [ChatService: [String: ScrollSpot]] = [:]

    /// When a chat comes back on screen: return to where you were in this conversation, or — the first time you
    /// open it — to its newest message. Runs twice: the site may still be rendering the thread.
    func restoreScroll(_ service: ChatService) {
        guard service.scrollsToLatest, let view = webViews[service] else { return }
        let path = view.url?.path() ?? "/"
        let spot = scrollSpots[service]?[path] ?? ScrollSpot(top: 0, atBottom: true)
        for delay in [0.15, 0.8] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                Task {
                    _ = try? await view.callAsyncJavaScript(ScrollMemory.restoreScript,
                                                            arguments: ["top": spot.top, "atBottom": spot.atBottom],
                                                            in: nil, contentWorld: .defaultClient)
                }
            }
        }
    }

    func goHome() {
        webViews[service]?.load(URLRequest(url: service.home))
    }

    func reload() {
        webViews[service]?.reload()
    }

    func goBack() {
        webViews[service]?.goBack()
    }

    // MARK: - Copy link / add project

    func copyLink() {
        guard let url = webViews[service]?.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        showToast("Link copied")
    }

    /// The project the current page is in (a project page, or a chat inside one), if any.
    var currentProject: AskProject? {
        guard service.supportsProjects, let url = pageURLs[service] else { return nil }
        return service.projects(fromLinks: [["href": url.absoluteString, "name": ""]]).first
    }

    func isSaved(_ project: AskProject) -> Bool {
        projects[service]?.contains { $0.url == project.url } ?? false
    }

    /// Adds the current page's project to the Ask menus, named from the page when it's the project's own page.
    func addCurrentProject() {
        guard var project = currentProject, !isSaved(project), let view = webViews[service] else { return }
        let service = self.service
        Task {
            if project.name.isEmpty, view.url?.path().hasSuffix("/project") == true || service == .claude {
                let raw = try? await view.callAsyncJavaScript(ChatService.projectNameScript, arguments: [:], in: nil,
                                                              contentWorld: .defaultClient)
                project.name = ChatService.cleanName(raw as? String ?? "")
            }
            if project.name.isEmpty { project.name = ChatService.placeholderName(for: project.url) }
            setProjects((projects[service] ?? []) + [project], for: service)
            showToast("Added “\(project.name)” — rename it in Settings")
        }
    }

    private func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    func openInBrowser() {
        NSWorkspace.shared.open(webViews[service]?.url ?? service.home)
    }

    public func makeExpandedView() -> AnyView {
        AnyView(ChatView(app: self))
    }
}

struct ChatView: View {
    @Bindable var app: ChatApp

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                ServiceTabs(app: app)

                if !app.showingOverview && !app.showingChatList && app.loading.contains(app.service) {
                    NotchSpinner(size: 11, color: .white.opacity(0.6), lineWidth: 1.6)
                }
                Spacer()
                ChatsButton(app: app)
                if app.showingChatList {
                    SyncChatsButton(app: app)
                } else if app.showingOverview {
                    button("arrow.clockwise", "Refresh agents") { Task { await app.agentMonitor.refresh() } }
                    Button { app.composingAgent.toggle() } label: {
                        Label("New Agent", systemImage: "plus")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(.white.opacity(app.composingAgent ? 0.25 : 0.12)))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                } else {
                    if let toast = app.toast {
                        Text(toast)
                            .font(.system(size: 11))
                            .foregroundStyle(.green)
                            .lineLimit(1)
                            .transition(.opacity)
                    }
                    Group {
                        if let project = app.currentProject, !app.isSaved(project) {
                            button("folder.badge.plus", "Add this project to the Ask menus", app.addCurrentProject)
                        }
                        button("link", "Copy link to this page", app.copyLink)
                        button("chevron.left", "Back", app.goBack)
                        button("square.and.pencil", "New chat", app.goHome)
                        button("arrow.clockwise", "Reload", app.reload)
                        button("macwindow.badge.plus", "Pop out into a window", app.popOut)
                        button("safari", "Open in browser", app.openInBrowser)
                    }
                }
            }

            if app.showingChatList {
                ChatListView(app: app)
            } else if app.showingOverview {
                AgentsOverview(app: app)
            } else {
            // Both services stay loaded; only the selected one is shown.
            ZStack {
                ForEach(ChatService.allCases) { service in
                    if service == app.service {
                        if app.poppedOut.contains(service) {
                            VStack(spacing: 8) {
                                Text("\(service.name) is open in its own window.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.6))
                                HStack {
                                    Button("Show Window", action: app.showWindow)
                                    Button("Bring Back", action: app.bringBack)
                                }
                                .controlSize(.small)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            NSViewHost(view: app.webView(for: service), onAttach: { app.restoreScroll(service) })
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .onAppear { if !app.showingOverview && !app.showingChatList { app.markSeen(app.service) } }
        .onChange(of: app.service) { _, service in app.markSeen(service) }
        .onChange(of: app.showingOverview) { _, overview in if !overview { app.markSeen(app.service) } }
    }

    private func button(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Overview | ChatGPT | Claude | Muse switcher showing each one's state.
private struct ServiceTabs: View {
    @Bindable var app: ChatApp

    var body: some View {
        HStack(spacing: 2) {
            let overviewSelected = app.showingOverview && !app.showingChatList
            Button {
                app.showingOverview = true
                app.showingChatList = false
            } label: {
                HStack(spacing: 5) {
                    Text("Overview")
                    if !app.unseenAgents.isEmpty {
                        Circle().fill(.orange).frame(width: 6, height: 6)
                    }
                }
                .font(.system(size: 12, weight: overviewSelected ? .semibold : .regular))
                .foregroundStyle(overviewSelected ? .white : .white.opacity(0.65))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(overviewSelected ? 0.2 : 0)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            ForEach(ChatService.allCases) { service in
                let selected = !app.showingOverview && !app.showingChatList && service == app.service
                Button { app.show(service) } label: {
                    HStack(spacing: 5) {
                        Text(service.name)
                        if app.isBusy(service) {
                            NotchSpinner(size: 10, lineWidth: 1.6)
                        } else if app.unread.contains(service) {
                            Circle().fill(.green).frame(width: 6, height: 6)
                        }
                    }
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .white : .white.opacity(0.65))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(selected ? 0.2 : 0)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(app.isBusy(service) ? "\(service.name) is writing a reply" : service.name)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.08)))
    }
}
