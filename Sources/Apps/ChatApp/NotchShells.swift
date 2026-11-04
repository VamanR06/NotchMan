import AppKit
import NotchKit
import SwiftUI

/// Terminals of your own in the notch, not tied to an agent: shell tabs, each started in a folder you pick.
/// They keep running when the notch closes or you go back to the Overview.
@MainActor @Observable
final class ShellWorkspace {
    private(set) var tabs: [AgentTerminal.ShellTab] = []
    var selected: UUID?
    /// The user clicked into one of the terminals.
    @ObservationIgnored var onClick: (() -> Void)? {
        didSet { tabs.forEach { $0.session.onClick = onClick } }
    }
    /// ⌘T in one of the terminals.
    @ObservationIgnored var onNewTab: (() -> Void)?
    /// The last tab closed (by `exit` or its ×).
    @ObservationIgnored var onEmpty: (() -> Void)?
    @ObservationIgnored private var nextNumber = 1

    var selectedTab: AgentTerminal.ShellTab? {
        tabs.first { $0.id == selected } ?? tabs.last
    }

    /// Opens an interactive shell in `folder` and selects it.
    @discardableResult
    func add(in folder: String) -> AgentTerminal.ShellTab {
        let session = TerminalSession()
        let tab = AgentTerminal.ShellTab(number: nextNumber, session: session)
        nextNumber += 1
        session.onExit = { [weak self] in self?.remove(tab.id) }  // `exit` closes the tab
        session.onClick = onClick
        session.onNewTab = { [weak self] in self?.onNewTab?() }
        session.runShell(in: folder)
        tabs.append(tab)
        selected = tab.id
        return tab
    }

    func close(_ id: UUID) {
        tabs.first { $0.id == id }?.session.stop()
        remove(id)
    }

    func closeAll() {
        tabs.forEach { $0.session.stop() }
        tabs.removeAll()
        selected = nil
        onEmpty?()
    }

    private func remove(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        if selected == id {
            // Select a neighbouring tab.
            selected = (tabs.indices.contains(index) ? tabs[index] : tabs.last)?.id
        }
        if tabs.isEmpty { onEmpty?() }
    }

    /// What a tab is called: the folder its shell is in (as of its last refresh), else its number.
    static func title(_ tab: AgentTerminal.ShellTab) -> String {
        guard let folder = tab.session.currentDirectory ?? tab.session.directory else { return "Shell \(tab.number)" }
        return folder == NSHomeDirectory() ? "~" : URL(fileURLWithPath: folder).lastPathComponent
    }
}

/// Spots `git clone` (and `gh repo clone`, which runs it) in a terminal's output: git prints
/// "Cloning into 'name'..." as it starts.
struct CloneDetector {
    /// The unfinished last line of what's been fed so far.
    private var partial = ""

    /// Takes the next piece of output; returns the folders (as git printed them) that clones started into.
    mutating func feed(_ text: String) -> [String] {
        // Terminals end lines with "\r\n", which Swift counts as one Character (not "\n"); progress lines use "\r".
        var lines = (partial + text).split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        // Progress lines can be long and never end in a newline; only the start of a line matters.
        partial = String(lines.removeLast().prefix(1024))
        return lines.compactMap { Self.folder(in: String($0)) }
    }

    /// The folder in a "Cloning into 'name'..." line (not a bare repository: there's nothing to open).
    static func folder(in line: String) -> String? {
        let plain = line.replacing(#/\x1B\[[0-9;?]*[A-Za-z]/#, with: "")
        guard let match = plain.firstMatch(of: #/Cloning into '(.+)'\.\.\./#) else { return nil }
        return String(match.1)
    }
}

/// The notch's own terminals: header (back, tabs, Open in VS Code, Finder, close all), then the selected shell.
struct ShellScreen: View {
    let app: ChatApp
    @Bindable var shells: ShellWorkspace

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if let tab = shells.selectedTab {
                pane(tab.session).id(tab.id)
            }
        }
        .task {
            // Tab names, the folder buttons and the clone banner follow `cd` and running commands.
            while !Task.isCancelled {
                shells.tabs.forEach { $0.session.refresh() }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private var folder: String? {
        shells.selectedTab.flatMap { $0.session.currentDirectory ?? $0.session.directory }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button { app.backToOverview() } label: {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.7))
            .help("Back to Overview (terminals keep running)")

            Text("Terminal")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)

            tabs

            Spacer(minLength: 4)

            if let folder {
                let shown = folder.replacingOccurrences(of: NSHomeDirectory(), with: "~")
                Button { app.editor.open(folder) } label: {
                    Label("Open in \(app.editor.name)", systemImage: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(.white.opacity(0.12)))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .help("Open \(shown) in \(app.editor.name)")
                iconButton("folder", help: "Show \(shown) in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)])
                }
            }
            iconButton("xmark", help: "Close all terminals") { shells.closeAll() }
        }
    }

    /// Folder-named tabs, then + (another shell in this folder; its menu picks a different one).
    private var tabs: some View {
        HStack(spacing: 2) {
            ForEach(shells.tabs) { tab in
                let selected = tab.id == shells.selectedTab?.id
                HStack(spacing: 4) {
                    if tab.session.isBusy {
                        NotchSpinner(size: 8, lineWidth: 1.2)
                    } else {
                        Image(systemName: "terminal").font(.system(size: 9)).foregroundStyle(.white.opacity(0.6))
                    }
                    Text(ShellWorkspace.title(tab)).lineLimit(1).frame(maxWidth: 110)
                    Button { shells.close(tab.id) } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.5))
                    .help("Close this terminal")
                }
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? .white : .white.opacity(0.65))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(selected ? 0.2 : 0)))
                .contentShape(Rectangle())
                .onTapGesture {
                    shells.selected = tab.id
                    tab.session.focusWhenShown()
                }
                .help(tab.session.currentDirectory?.replacingOccurrences(of: NSHomeDirectory(), with: "~") ?? "")
            }
            Menu {
                Button("Home") { app.openShell(in: NSHomeDirectory()) }
                let recent = app.agentMonitor.recentFolders
                if !recent.isEmpty {
                    Section("Projects") {
                        ForEach(recent, id: \.self) { path in
                            Button(path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) { app.openShell(in: path) }
                        }
                    }
                }
                Divider()
                Button("Choose Folder…") {
                    if let path = ChatApp.chooseFolder(startingIn: folder) { app.openShell(in: path) }
                }
            } label: {
                Image(systemName: "plus").font(.system(size: 10, weight: .bold))
            } primaryAction: {
                app.openShell(in: folder)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .foregroundStyle(.white.opacity(0.7))
            .padding(.horizontal, 4)
            .help("New terminal here (⌘T) — or pick a folder from the menu")
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.08)))
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.7))
        .help(help)
    }

    private func pane(_ session: TerminalSession) -> some View {
        ZStack {
            NSViewHost(view: session.view)
            if let preview = session.preview {
                FilePreviewOverlay(preview: preview, close: session.closePreview)
                    .id(preview.id)
            }
            CloneBanner(app: app, session: session)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10).fill(.black))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.12)))
    }
}

/// After `git clone` in a terminal: the new folder, to open in the editor or `cd` into. Sits in the terminal's
/// bottom-right corner until used or dismissed (or the folder goes away, e.g. the clone failed).
struct CloneBanner: View {
    let app: ChatApp
    let session: TerminalSession

    var body: some View {
        if let folder = session.clonedFolder, FileManager.default.fileExists(atPath: folder) {
            let name = URL(fileURLWithPath: folder).lastPathComponent
            HStack(spacing: 8) {
                if session.isBusy {
                    NotchSpinner(size: 10, lineWidth: 1.5)
                    Text("Cloning \(name)…")
                } else {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Cloned \(name)")
                }
                Button {
                    app.editor.open(folder)
                    session.clonedFolder = nil
                } label: {
                    Text("Open in \(app.editor.name)")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(Capsule().fill(.white))
                        .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
                .help(folder.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                if !session.isBusy {
                    Button("cd") {
                        // At the prompt; Ctrl-U first clears anything half-typed there.
                        session.view.send(txt: "\u{15}cd \(Shell.quote(folder))\r")
                        session.clonedFolder = nil
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))
                    .help("Go into \(name) in this terminal")
                }
                Button { session.clonedFolder = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.5))
                .help("Dismiss")
            }
            .font(.system(size: 11))
            .foregroundStyle(.white)
            .padding(.leading, 10).padding(.trailing, 8).padding(.vertical, 5)
            .background(Capsule().fill(Color(white: 0.16)))
            .overlay(Capsule().stroke(.white.opacity(0.18)))
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .transition(.opacity)
        }
    }
}

extension ChatApp {
    /// Asks for a folder, starting in `start`.
    static func chooseFolder(startingIn start: String? = nil) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if let start { panel.directoryURL = URL(fileURLWithPath: start) }
        NSApp.activate()
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
