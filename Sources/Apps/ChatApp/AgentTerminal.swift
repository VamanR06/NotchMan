import AppKit
import SwiftTerm
import SwiftUI

/// One terminal and its process. Lives as long as this object, so collapsing the notch keeps it going.
@MainActor @Observable
final class TerminalSession: Identifiable {
    let id = UUID()
    /// False once the process exits.
    private(set) var isRunning = false
    /// Title the program sets (OSC 0/2).
    private(set) var title = ""
    @ObservationIgnored let view: NotchTerminalView
    @ObservationIgnored private let events: TerminalEvents
    /// Every key pressed in this terminal (after shortcut translation).
    @ObservationIgnored var onKey: ((NSEvent) -> Void)?
    /// The process exited.
    @ObservationIgnored var onExit: (() -> Void)?

    init() {
        view = NotchTerminalView(frame: CGRect(x: 0, y: 0, width: 680, height: 380))
        events = TerminalEvents()
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.nativeBackgroundColor = .black
        view.nativeForegroundColor = NSColor(white: 0.92, alpha: 1)
        view.caretColor = .systemOrange
        view.optionAsMetaKey = true
        view.processDelegate = events
        events.onExit = { [weak self] in
            self?.isRunning = false
            self?.onExit?()
        }
        events.onTitle = { [weak self] title in self?.title = title }
        view.onKey = { [weak self] event in self?.onKey?(event) }
    }

    private static var environment: [String] {
        Terminal.getEnvironmentVariables(termName: "xterm-256color")
    }

    /// Runs `command` in a login zsh (so the user's PATH applies).
    func run(_ command: String) {
        view.startProcess(executable: "/bin/zsh", args: ["-l", "-c", command], environment: Self.environment, execName: "zsh")
        isRunning = true
    }

    /// An interactive login shell in `folder`, like a new Terminal tab.
    func runShell(in folder: String) {
        view.startProcess(executable: "/bin/zsh", args: ["-l"], environment: Self.environment, execName: "-zsh",
                          currentDirectory: folder)
        isRunning = true
    }

    func stop() {
        if isRunning { view.terminate() }
        isRunning = false
    }

    /// Puts keyboard focus in this terminal.
    func focus() {
        view.window?.makeKey()
        view.window?.makeFirstResponder(view)
    }

    /// The visible text (for tests and diagnostics).
    var screenText: String {
        let terminal = view.getTerminal()
        return (0..<terminal.rows).compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true) }
            .joined(separator: "\n")
    }
}

/// A background agent's workspace in the notch: its Claude Code terminal (`claude attach <id>`) plus any shells
/// opened alongside it in the agent's project folder.
@MainActor @Observable
final class AgentTerminal: Identifiable {
    /// A shell tab.
    struct ShellTab: Identifiable {
        let number: Int
        let session: TerminalSession
        var id: UUID { session.id }
    }

    enum Tab: Hashable {
        case claude
        case shell(UUID)
    }

    let id: String
    private(set) var agent: ClaudeAgent
    let claude = TerminalSession()
    private(set) var shells: [ShellTab] = []
    var selected: Tab = .claude
    /// Claude on top, a shell below.
    var split = false
    /// Share of the split height given to Claude (the shell gets the rest); adjustable by dragging.
    var splitRatio: CGFloat = 0.6
    /// Called when Claude Code switches to its own agent list (← from the session); the app shows NotchMan's
    /// Overview instead.
    @ObservationIgnored var onAgentList: (() -> Void)?
    @ObservationIgnored private var watch: Task<Void, Never>?
    @ObservationIgnored private var nextShellNumber = 1

    init(agent: ClaudeAgent) {
        id = agent.id
        self.agent = agent
        claude.onKey = { [weak self] event in self?.keyPressed(event) }
    }

    // The Claude session is the workspace's main terminal.
    var view: NotchTerminalView { claude.view }
    var isRunning: Bool { claude.isRunning }
    var title: String { claude.title }
    var screenText: String { claude.screenText }

    /// Starts (or restarts) `claude attach` through a login shell, so the user's PATH applies.
    func start(claudePath: String) {
        guard let shortID = agent.shortID else { return }
        run("cd \(Shell.quote(agent.cwd)) 2>/dev/null; exec \(Shell.quote(claudePath)) attach \(Shell.quote(shortID))")
    }

    func run(_ command: String) {
        claude.run(command)
    }

    /// Ends everything in the workspace. The agent itself keeps running in the background.
    func stop() {
        claude.stop()
        shells.forEach { $0.session.stop() }
        shells.removeAll()
        selected = .claude
    }

    func update(_ agent: ClaudeAgent) {
        self.agent = agent
    }

    /// Focuses whichever terminal is selected.
    func focus() {
        selectedSession.focus()
    }

    // MARK: - Shells

    /// Opens an interactive shell in the agent's project folder and selects it.
    @discardableResult
    func addShell() -> ShellTab {
        let session = TerminalSession()
        let shell = ShellTab(number: nextShellNumber, session: session)
        nextShellNumber += 1
        session.onExit = { [weak self] in self?.removeShell(shell.id) }  // `exit` closes the tab
        session.runShell(in: agent.cwd)
        shells.append(shell)
        selected = .shell(shell.id)
        return shell
    }

    func closeShell(_ id: UUID) {
        shells.first { $0.id == id }?.session.stop()
        removeShell(id)
    }

    private func removeShell(_ id: UUID) {
        guard let index = shells.firstIndex(where: { $0.id == id }) else { return }
        shells.remove(at: index)
        if selected == .shell(id) {
            // Select a neighbouring shell, or Claude when none are left.
            let neighbour = shells.indices.contains(index) ? shells[index] : shells.last
            selected = neighbour.map { .shell($0.id) } ?? .claude
        }
        if shells.isEmpty { split = false }
    }

    var selectedSession: TerminalSession {
        if case .shell(let id) = selected, let shell = shells.first(where: { $0.id == id }) { return shell.session }
        return claude
    }

    /// The shell shown under Claude in split view: the selected one, else the most recent.
    var splitShell: ShellTab? {
        if case .shell(let id) = selected, let shell = shells.first(where: { $0.id == id }) { return shell }
        return shells.last
    }

    // MARK: - ← out of the session

    /// ← either moves the cursor (while editing) or makes Claude Code open its agent list; only the program
    /// knows which. So let it through, and if the agent list appears, hand over to NotchMan's Overview.
    private func keyPressed(_ event: NSEvent) {
        let plainLeftArrow = event.keyCode == TerminalKeyMap.KeyCode.left
            && event.modifierFlags.intersection([.command, .option, .shift, .control]).isEmpty
        guard plainLeftArrow, isRunning else { return }
        watch?.cancel()
        watch = Task { [weak self] in
            for _ in 0..<15 {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled else { return }
                if Self.isClaudeAgentList(self.screenText) {
                    self.onAgentList?()
                    return
                }
            }
        }
    }

    /// Claude Code's agent list (what `claude attach` shows after ←), recognized by its prompt and footer.
    static func isClaudeAgentList(_ screen: String) -> Bool {
        screen.contains("describe a task for a new session") && screen.contains("enter to return")
    }
}

/// Terminal view that takes keyboard focus when clicked, even inside the non-activating notch panel, and
/// translates macOS editing shortcuts into what terminal programs expect (see `TerminalKeyMap`).
final class NotchTerminalView: LocalProcessTerminalView {
    /// Sees every key pressed in this terminal (after our shortcut translation).
    var onKey: ((NSEvent) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        Self.installKeyMonitor()
    }

    /// SwiftTerm's keyDown can't be overridden, so translate shortcuts just before AppKit dispatches them
    /// (this also runs before the Edit menu, which keeps ⌘C/⌘V/⌘A since we don't map those).
    private static var keyMonitor: Any?

    private static func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Local monitors run on the main thread.
            nonisolated(unsafe) let event = event
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let terminal = event.window?.firstResponder as? NotchTerminalView else { return false }
                let handled = terminal.handle(event)
                if !handled { terminal.onKey?(event) }
                return handled
            }
            return handled ? nil : event
        }
    }

    /// Sends our translation of `event`, if it's one of the mapped shortcuts.
    func handle(_ event: NSEvent) -> Bool {
        let kittyActive = !getTerminal().keyboardEnhancementFlags.isEmpty
        switch TerminalKeyMap.action(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers,
                                     modifiers: event.modifierFlags, kittyKeyboard: kittyActive) {
        case .send(let bytes):
            send(data: bytes[...])
            return true
        case .clear:
            // Like Terminal's ⌘K: drop the scrollback, and ask the program to redraw a clean screen (Ctrl-L).
            getTerminal().clearScrollback()
            send(data: [0x0c][...])
            return true
        case nil:
            return false
        }
    }
}

/// macOS editing shortcuts → terminal input, matching Terminal/iTerm2 conventions (and Claude Code's
/// `/terminal-setup`, which binds ⇧↩ to ESC+Return for a newline).
enum TerminalKeyMap {
    enum Action: Equatable {
        case send([UInt8])
        case clear
    }

    enum KeyCode {
        static let returnKey: UInt16 = 36
        static let keypadEnter: UInt16 = 76
        static let delete: UInt16 = 51
        static let forwardDelete: UInt16 = 117
        static let left: UInt16 = 123
        static let right: UInt16 = 124
    }

    static func action(keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags,
                       kittyKeyboard: Bool) -> Action? {
        let mods = modifiers.intersection([.command, .option, .shift, .control])
        switch (keyCode, mods) {
        case (KeyCode.returnKey, [.shift]), (KeyCode.keypadEnter, [.shift]):
            // With the kitty keyboard protocol on, the terminal already encodes ⇧↩ unambiguously.
            return kittyKeyboard ? nil : .send([0x1B, 0x0D])        // ESC CR: newline, don't submit
        case (KeyCode.delete, [.command]):
            return .send([0x15])                                   // Ctrl-U: delete to line start
        case (KeyCode.delete, [.option]):
            return .send([0x1B, 0x7F])                             // ESC DEL: delete previous word
        case (KeyCode.forwardDelete, [.command]):
            return .send([0x0B])                                   // Ctrl-K: delete to line end
        case (KeyCode.forwardDelete, [.option]):
            return .send([0x1B, 0x64])                             // ESC d: delete next word
        case (KeyCode.left, [.command]):
            return .send([0x01])                                   // Ctrl-A: line start
        case (KeyCode.right, [.command]):
            return .send([0x05])                                   // Ctrl-E: line end
        case (KeyCode.left, [.option]):
            return .send([0x1B, 0x62])                             // ESC b: word back
        case (KeyCode.right, [.option]):
            return .send([0x1B, 0x66])                             // ESC f: word forward
        default:
            if mods == [.command], characters?.lowercased() == "k" { return .clear }
            return nil
        }
    }
}

/// Process callbacks from SwiftTerm.
private final class TerminalEvents: LocalProcessTerminalViewDelegate {
    var onExit: (@MainActor () -> Void)?
    var onTitle: (@MainActor (String) -> Void)?

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        let onTitle = self.onTitle
        DispatchQueue.main.async { MainActor.assumeIsolated { onTitle?(title) } }
    }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        let onExit = self.onExit
        DispatchQueue.main.async { MainActor.assumeIsolated { onExit?() } }
    }
}

/// The in-notch workspace screen: header (back, name, tabs, split, Open in Terminal, close), then the
/// selected terminal — or Claude on top and a shell below when split.
struct AgentTerminalScreen: View {
    let app: ChatApp
    @Bindable var terminal: AgentTerminal

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if terminal.split, let shell = terminal.splitShell {
                // Explicit heights: letting the stack divide the space squeezed the shell to a sliver.
                GeometryReader { geo in
                    let heights = SplitLayout.heights(total: geo.size.height, ratio: terminal.splitRatio)
                    VStack(spacing: 0) {
                        pane(terminal.claude, detachedOverlay: true)
                            .frame(height: heights.top)
                        SplitHandle(ratio: $terminal.splitRatio, total: geo.size.height)
                        pane(shell.session, detachedOverlay: false)
                            .frame(height: heights.bottom)
                    }
                }
            } else {
                switch terminal.selected {
                case .claude:
                    pane(terminal.claude, detachedOverlay: true)
                case .shell:
                    pane(terminal.selectedSession, detachedOverlay: false).id(terminal.selectedSession.id)
                }
            }
        }
        .onChange(of: terminal.selected) { _, _ in
            DispatchQueue.main.async { terminal.focus() }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button { app.backToOverview() } label: {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.7))
            .help("Back to Overview (terminals keep running)")

            Text(terminal.agent.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(maxWidth: 170, alignment: .leading)

            TerminalTabs(terminal: terminal)

            Spacer(minLength: 4)

            iconButton(terminal.split ? "rectangle" : "rectangle.split.1x2",
                       help: terminal.split ? "Show one terminal" : "Split: Claude above a shell") {
                if terminal.shells.isEmpty { terminal.addShell() }
                terminal.split.toggle()
            }
            iconButton("macwindow", help: "Detach here and attach Claude in a new Terminal window") {
                app.openInTerminalApp(terminal.agent)
            }
            iconButton("xmark", help: "Close these terminals (the agent keeps running)") {
                app.closeTerminal(terminal.id)
            }
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.7))
        .help(help)
    }

    private func pane(_ session: TerminalSession, detachedOverlay: Bool) -> some View {
        ZStack {
            NSViewHost(view: session.view, onAttach: {
                if session === terminal.selectedSession { session.focus() }
            })
            if detachedOverlay && !session.isRunning {
                VStack(spacing: 8) {
                    Text("Detached from \(terminal.agent.name).")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.8))
                    HStack {
                        Button("Reattach") { app.reattach(terminal) }
                        Button("Back to Overview") { app.closeTerminal(terminal.id) }
                    }
                    .controlSize(.small)
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.85)))
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10).fill(.black))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(.white.opacity(session === terminal.selectedSession && terminal.split ? 0.3 : 0.12)))
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            // Clicking a pane in split view selects it.
            if session === terminal.claude {
                terminal.selected = .claude
            } else if let shell = terminal.shells.first(where: { $0.session === session }) {
                terminal.selected = .shell(shell.id)
            }
        })
    }
}

/// Pane heights for the split view.
enum SplitLayout {
    static let handleHeight: CGFloat = 10
    /// Each pane keeps at least this much (about 8 rows of 12pt text plus padding).
    static let minimumPane: CGFloat = 130

    static func heights(total: CGFloat, ratio: CGFloat) -> (top: CGFloat, bottom: CGFloat) {
        let available = max(total - handleHeight, 0)
        guard available >= minimumPane * 2 else { return (available / 2, available / 2) }
        let top = min(max(available * ratio, minimumPane), available - minimumPane)
        return (top, available - top)
    }
}

/// Drag to resize the split.
private struct SplitHandle: View {
    @Binding var ratio: CGFloat
    let total: CGFloat
    @State private var startRatio: CGFloat?
    @State private var hovering = false

    var body: some View {
        Capsule()
            .fill(.white.opacity(hovering ? 0.5 : 0.25))
            .frame(width: 44, height: 4)
            .frame(maxWidth: .infinity)
            .frame(height: SplitLayout.handleHeight)
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { drag in
                    let start = startRatio ?? ratio
                    startRatio = start
                    let available = max(total - SplitLayout.handleHeight, 1)
                    ratio = min(max(start + drag.translation.height / available, 0.2), 0.8)
                }
                .onEnded { _ in startRatio = nil })
            .help("Drag to resize")
    }
}

/// Claude | Shell 1 | Shell 2 | + — the agent's terminals.
private struct TerminalTabs: View {
    @Bindable var terminal: AgentTerminal

    var body: some View {
        HStack(spacing: 2) {
            tab(.claude, title: "Claude", running: terminal.claude.isRunning, closable: nil)
            ForEach(terminal.shells) { shell in
                tab(.shell(shell.id), title: "Shell \(shell.number)", running: true, closable: shell.id)
            }
            Button { terminal.addShell() } label: {
                Image(systemName: "plus").font(.system(size: 10, weight: .bold)).frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.7))
            .help("New shell in \(terminal.agent.project)")
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.08)))
    }

    private func tab(_ id: AgentTerminal.Tab, title: String, running: Bool, closable: UUID?) -> some View {
        let selected = terminal.selected == id
        return HStack(spacing: 4) {
            Image(systemName: id == .claude ? "sparkle" : "terminal")
                .font(.system(size: 9))
                .foregroundStyle(id == .claude ? .orange : .white.opacity(0.6))
            Text(title)
            if let closable {
                Button { terminal.closeShell(closable) } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.5))
                .help("Close this shell")
            }
        }
        .font(.system(size: 11, weight: selected ? .semibold : .regular))
        .foregroundStyle(selected ? .white : .white.opacity(running ? 0.65 : 0.35))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(selected ? 0.2 : 0)))
        .contentShape(Rectangle())
        .onTapGesture { terminal.selected = id }
    }
}

/// Hosts a long-lived AppKit view (a terminal or web view) that outlives SwiftUI's containers: it survives the
/// notch collapsing and moves between layouts (e.g. split ↔ single pane).
///
/// - The most recently created container owns the view. When a layout changes, the old container can get one
///   last update after the new one took the view; without ownership it would pull the view back and then be
///   discarded with it, leaving a blank pane.
/// - The view is only attached once its container has a real size. A zero-size moment makes web pages clamp
///   their scroll position to the top and makes terminals resize to zero columns.
struct NSViewHost: NSViewRepresentable {
    let view: NSView
    var onAttach: (() -> Void)?

    @MainActor fileprivate static var owners: [ObjectIdentifier: ObjectIdentifier] = [:]

    func makeNSView(context: Context) -> HostContainer {
        let container = HostContainer()
        Self.owners[ObjectIdentifier(view)] = ObjectIdentifier(container)
        container.hosted = view
        container.onAttach = onAttach
        container.needsLayout = true
        return container
    }

    func updateNSView(_ container: HostContainer, context: Context) {
        container.onAttach = onAttach
        guard Self.owns(container, view), view.superview !== container else { return }
        container.needsLayout = true
    }

    static func dismantleNSView(_ container: HostContainer, coordinator: ()) {
        // Release ownership only if this container still holds it.
        for (key, owner) in owners where owner == ObjectIdentifier(container) { owners[key] = nil }
    }

    /// Whether `container` currently owns `view`.
    @MainActor static func owns(_ container: NSView, _ view: NSView) -> Bool {
        owners[ObjectIdentifier(view)] == ObjectIdentifier(container)
    }
}

/// Container that takes its hosted view once it has been laid out at a real size.
final class HostContainer: NSView {
    weak var hosted: NSView?
    var onAttach: (() -> Void)?

    override func layout() {
        super.layout()
        guard let hosted, bounds.width > 1, bounds.height > 1, NSViewHost.owns(self, hosted) else { return }
        if hosted.superview !== self {
            subviews.forEach { $0.removeFromSuperview() }
            hosted.removeFromSuperview()
            hosted.frame = bounds
            hosted.autoresizingMask = [.width, .height]
            addSubview(hosted)
            if let onAttach { DispatchQueue.main.async { onAttach() } }
        }
    }
}
