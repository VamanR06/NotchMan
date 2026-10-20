import AppKit
import SwiftUI
import WebKit
import NotchKit

/// ChatGPT and Claude in the notch, as their real websites (signed in with your own accounts).
///
/// Nothing is sent anywhere except what you type into the sites yourself, so usage is the same as using
/// chatgpt.com / claude.ai in a browser. Pages only load the first time a service is shown.
@MainActor @Observable
public final class ChatApp: NotchApp {
    public let id = "chat"
    public let name = "Chat"
    public let iconSystemName = "bubble.left.and.text.bubble.right"
    public var expandedHeight: CGFloat { 460 }
    public var expandedWidth: CGFloat { 720 }

    var service: ChatService = .chatgpt {
        didSet { context?.defaults.set(service.rawValue, forKey: "service") }
    }
    private(set) var loading: Set<ChatService> = []
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
        for service in ChatService.allCases {
            if let data = context.defaults.data(forKey: "projects.\(service.rawValue)"),
               let saved = try? JSONDecoder().decode([AskProject].self, from: data) {
                projects[service] = saved
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
        ReplyWatcher.install(in: config.userContentController, handler: ReplyMessageProxy { [weak self] busy, title in
            self?.replyStateChanged(service, busy: busy, pageTitle: title)
        })
        let view = NotchWebView(frame: .zero, configuration: config)
        view.customUserAgent = Self.userAgent
        view.navigationDelegate = coordinator
        view.uiDelegate = coordinator
        view.allowsBackForwardNavigationGestures = true
        view.underPageBackgroundColor = .black
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
            if let opened = message.payload["service"].flatMap(ChatService.init(rawValue:)) { service = opened }
            return
        }
        guard message.name == NotchMessage.chatPromptName, let text = message.payload["text"] else { return }
        let target = message.payload["service"].flatMap(ChatService.init(rawValue:)) ?? .chatgpt
        service = target
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
        return (context?.isVisible ?? false) && self.service == service && !poppedOut.contains(service)
    }

    /// Called by the view when a service is on screen.
    func markSeen(_ service: ChatService) {
        unread.remove(service)
    }

    func isBusy(_ service: ChatService) -> Bool { busySince[service] != nil }

    /// Collapsed notch: a spinner while any service is writing, plus each busy (white) or finished (green) service.
    /// Outranks music so a pending reply isn't hidden by what's playing.
    /// Chip: a spinner and the service still writing (e.g. "GPT", or "GPT +1" if several), or a green check
    /// and the service whose reply is waiting. Outranks music so a pending reply isn't hidden.
    public var activity: NotchActivity? {
        let busy = ChatService.allCases.filter(isBusy)
        let done = ChatService.allCases.filter { unread.contains($0) && !isBusy($0) }
        guard let first = busy.first ?? done.first else { return nil }
        let others = busy.count + done.count - 1
        let label = first.shortName + (others > 0 ? " +\(others)" : "")
        return NotchActivity(priority: busy.isEmpty ? 12 : 14) {
            if busy.isEmpty {
                NotchChip(label, tint: .green) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                }
            } else {
                NotchChip(label) { NotchSpinner(size: 11, lineWidth: 1.8) }
            }
        }
    }

    public var dockBadge: NotchBadge? {
        if ChatService.allCases.contains(where: isBusy) { return .busy }
        return unread.isEmpty ? nil : .dot(.green)
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
    func loadProjects(for service: ChatService) async throws -> Int {
        let view = webView(for: service)
        // A just-created view is still loading; give it a moment.
        for _ in 0..<40 where view.isLoading { try await Task.sleep(for: .milliseconds(250)) }
        let raw = try await view.callAsyncJavaScript(ChatService.linkScript, arguments: [:], in: nil, contentWorld: .defaultClient)
        let links = (raw as? [[String: Any]] ?? []).map { $0.compactMapValues { $0 as? String } }
        let found = service.projects(fromLinks: links)
        var merged = projects[service] ?? []
        let new = found.filter { project in !merged.contains { $0.url == project.url } }
        merged += new
        setProjects(merged, for: service)
        return new.count
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

    func goHome() {
        webViews[service]?.load(URLRequest(url: service.home))
    }

    func reload() {
        webViews[service]?.reload()
    }

    func goBack() {
        webViews[service]?.goBack()
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

                if app.loading.contains(app.service) {
                    NotchSpinner(size: 11, color: .white.opacity(0.6), lineWidth: 1.6)
                }
                Spacer()
                Group {
                    button("chevron.left", "Back", app.goBack)
                    button("square.and.pencil", "New chat", app.goHome)
                    button("arrow.clockwise", "Reload", app.reload)
                    button("macwindow.badge.plus", "Pop out into a window", app.popOut)
                    button("safari", "Open in browser", app.openInBrowser)
                }
            }

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
                            WebViewHost(webView: app.webView(for: service))
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .onAppear { app.markSeen(app.service) }
        .onChange(of: app.service) { _, service in app.markSeen(service) }
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

/// ChatGPT | Claude | Muse switcher showing each service's reply state.
private struct ServiceTabs: View {
    @Bindable var app: ChatApp

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ChatService.allCases) { service in
                let selected = service == app.service
                Button { app.service = service } label: {
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
