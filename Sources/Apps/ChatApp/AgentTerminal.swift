import AppKit
import SwiftTerm
import SwiftUI

/// An interactive terminal in the notch, attached to a background Claude Code agent (`claude attach <id>`).
/// The view (and the attach process) lives as long as this object, so collapsing the notch keeps it going.
@MainActor @Observable
final class AgentTerminal: Identifiable {
    let id: String
    private(set) var agent: ClaudeAgent
    /// False once `claude attach` exits (detached with ← / Ctrl+Z, or the session ended).
    private(set) var isRunning = false
    @ObservationIgnored let view: NotchTerminalView
    @ObservationIgnored private let events: TerminalEvents

    init(agent: ClaudeAgent) {
        id = agent.id
        self.agent = agent
        view = NotchTerminalView(frame: CGRect(x: 0, y: 0, width: 680, height: 380))
        events = TerminalEvents()
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.nativeBackgroundColor = .black
        view.nativeForegroundColor = NSColor(white: 0.92, alpha: 1)
        view.caretColor = .systemOrange
        view.optionAsMetaKey = true
        view.processDelegate = events
        events.onExit = { [weak self] in self?.isRunning = false }
    }

    /// Starts (or restarts) `claude attach` through a login shell, so the user's PATH applies.
    func start(claudePath: String) {
        guard let shortID = agent.shortID else { return }
        run("cd \(Shell.quote(agent.cwd)) 2>/dev/null; exec \(Shell.quote(claudePath)) attach \(Shell.quote(shortID))")
    }

    /// Runs `command` in a login zsh inside the terminal.
    func run(_ command: String) {
        view.startProcess(executable: "/bin/zsh", args: ["-l", "-c", command],
                          environment: Terminal.getEnvironmentVariables(termName: "xterm-256color"),
                          execName: "zsh")
        isRunning = true
    }

    /// The terminal's visible text (for tests and diagnostics).
    var screenText: String {
        let terminal = view.getTerminal()
        return (0..<terminal.rows).compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true) }
            .joined(separator: "\n")
    }

    /// Ends the attach process. The agent itself keeps running in the background.
    func stop() {
        if isRunning { view.terminate() }
        isRunning = false
    }

    func update(_ agent: ClaudeAgent) {
        self.agent = agent
    }

    /// Puts keyboard focus in the terminal.
    func focus() {
        view.window?.makeKey()
        view.window?.makeFirstResponder(view)
    }
}

/// Terminal view that takes keyboard focus when clicked, even inside the non-activating notch panel.
final class NotchTerminalView: LocalProcessTerminalView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
}

/// Process callbacks from SwiftTerm.
private final class TerminalEvents: LocalProcessTerminalViewDelegate {
    var onExit: (@MainActor () -> Void)?

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        let onExit = self.onExit
        DispatchQueue.main.async { MainActor.assumeIsolated { onExit?() } }
    }
}

/// The in-notch terminal screen: header with Back / Open in Terminal / Close, then the terminal.
struct AgentTerminalScreen: View {
    let app: ChatApp
    let terminal: AgentTerminal

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button { app.backToOverview() } label: {
                    Label("Overview", systemImage: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.7))

                Image(systemName: "terminal").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                Text(terminal.agent.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(terminal.agent.project)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                Spacer()
                Button { app.openInTerminalApp(terminal.agent) } label: {
                    Label("Open in Terminal", systemImage: "macwindow")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.7))
                .help("Detach here and attach in a new Terminal window")
                Button { app.closeTerminal(terminal.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.7))
                .help("Close (the agent keeps running)")
            }

            ZStack {
                NSViewHost(view: terminal.view, onAttach: { terminal.focus() })
                if !terminal.isRunning {
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
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.12)))
        }
    }
}

/// Hosts a long-lived AppKit view (it survives the notch collapsing and coming back).
struct NSViewHost: NSViewRepresentable {
    let view: NSView
    var onAttach: (() -> Void)?

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if view.superview !== container { attach(to: container) }
    }

    private func attach(to container: NSView) {
        container.subviews.forEach { $0.removeFromSuperview() }
        view.removeFromSuperview()
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        if let onAttach { DispatchQueue.main.async { onAttach() } }
    }
}
