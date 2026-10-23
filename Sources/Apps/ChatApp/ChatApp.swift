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
    /// Filters the Overview's sessions by name or project.
    var agentQuery = ""
    /// Show every finished session, not just the most recent few.
    var showAllCompleted = false

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
        editor = context.defaults.string(forKey: "editor").flatMap(AgentEditor.init(rawValue:)) ?? .vscode
        agentOpenMode = context.defaults.string(forKey: "agentOpenMode").flatMap(AgentOpenMode.init(rawValue:)) ?? .notch
        agentMonitor = ClaudeAgentsMonitor(defaults: context.defaults)
        agentMonitor.onEvents = { [weak self] events in self?.handle(events) }
        agentMonitor.start()
        for service in ChatService.allCases {
            if let data = context.defaults.data(forKey: "projects.\(service.rawValue)"),
               let saved = try? JSONDecoder().decode([AskProject].self, from: data) {
                // Older scans could keep icon glyphs in names (shown as "?" boxes).
                projects[service] = saved.map { AskProject(name: ChatService.cleanName($0.name), url: $0.url) }
            }
            defaultProjects[service] = context.defaults.string(forKey: "defaultProject.\(service.rawValue)")
        }
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
        ReplyWatcher.install(in: config.userContentController, handler: ReplyMessageProxy { [weak self] busy, title in
            self?.replyStateChanged(service, busy: busy, pageTitle: title)
        })
        let view = NotchWebView(frame: .zero, configuration: config)
        view.customUserAgent = Self.userAgent
        view.navigationDelegate = coordinator
        view.uiDelegate = coordinator
        view.allowsBackForwardNavigationGestures = true
        view.underPageBackgroundColor = .black
        observations.append(view.observe(\.url, options: [.new]) { [weak self] _, change in
            let url = change.newValue ?? nil
            Task { @MainActor in self?.pageURLs[service] = url }
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
        if message.name == NotchMessage.notificationOpenedName {
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

    private func replyStateChanged(_ service: ChatService, busy: Bool, pageTitle: String) {
        if busy {
            busySince[service] = busySince[service] ?? Date()
            return
        }
        guard let started = busySince.removeValue(forKey: service) else { return }
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
        return (context?.isVisible ?? false) && !showingOverview && self.service == service && !poppedOut.contains(service)
    }

    private var isLookingAtOverview: Bool {
        (context?.isVisible ?? false) && showingOverview
    }

    /// Switches to a chat tab.
    func show(_ service: ChatService) {
        self.service = service
        showingOverview = false
    }

    // MARK: - Claude Code agents

    private func handle(_ events: [AgentEvent]) {
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

    /// Back to the agent list; the terminal keeps running and can be reopened from its row.
    func backToOverview() {
        shownTerminalID = nil
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
        switch currentSummary?.kind {
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

                if !app.showingOverview && app.loading.contains(app.service) {
                    NotchSpinner(size: 11, color: .white.opacity(0.6), lineWidth: 1.6)
                }
                Spacer()
                if app.showingOverview {
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

            if app.showingOverview {
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
        .onAppear { if !app.showingOverview { app.markSeen(app.service) } }
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
            Button { app.showingOverview = true } label: {
                HStack(spacing: 5) {
                    Text("Overview")
                    if !app.unseenAgents.isEmpty {
                        Circle().fill(.orange).frame(width: 6, height: 6)
                    }
                }
                .font(.system(size: 12, weight: app.showingOverview ? .semibold : .regular))
                .foregroundStyle(app.showingOverview ? .white : .white.opacity(0.65))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(app.showingOverview ? 0.2 : 0)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            ForEach(ChatService.allCases) { service in
                let selected = !app.showingOverview && service == app.service
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
