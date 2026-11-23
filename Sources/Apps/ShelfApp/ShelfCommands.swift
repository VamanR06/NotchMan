import AppKit
import NotchKit

/// What the command bar can find and do in the Shelf: shelved files, downloads and folders; put a file in a folder,
/// open or preview it, open a folder.
extension ShelfApp {
    public func commands(for query: String) -> NotchCommands {
        let files = commandFiles
        let folders = dropCandidates()
        var items = files.map { file in
            CommandItem(id: "shelf.file:" + file.url.path, title: file.url.lastPathComponent, subtitle: file.where,
                        symbol: "doc", kind: file.kind, keywords: [file.url.pathExtension]) {
                NSWorkspace.shared.open(file.url)
            }
        }
        items += folders.map { candidate in
            CommandItem(id: "shelf.folder:" + candidate.id, title: candidate.url.lastPathComponent,
                        subtitle: ProjectDrop.displayPath(candidate.url.deletingLastPathComponent(), project: nil),
                        symbol: candidate.kind == .project ? "terminal" : "folder", kind: "Folder") {
                NSWorkspace.shared.open(candidate.url)
            }
        }
        let fileChoices = files.map { CommandChoice(id: $0.url.path, label: $0.url.lastPathComponent, path: $0.url.path, kind: .file) }
        let folderChoices = folders.map { CommandChoice(id: $0.id, label: $0.url.lastPathComponent, path: $0.id, kind: .folder) }
        let file = CommandParameter(name: "file", description: "file (on the shelf or in Downloads)", choices: fileChoices)
        let folder = CommandParameter(name: "folder", description: "folder", choices: folderChoices)
        let url = { (choice: CommandChoice?) in URL(fileURLWithPath: choice?.path ?? choice?.id ?? "") }
        let verb = moveFiles ? "Move" : "Copy"
        let actions = [
            CommandAction(id: "put_file", description: "Put a file into a folder (move or copy it there)", risk: .confirm,
                          symbol: "folder.badge.plus", parameters: [file, folder],
                          summary: { "\(verb) \($0["file"]?.label ?? "file") to \($0["folder"]?.label ?? "folder")" },
                          perform: { [weak self] in self?.drop([url($0["file"])], into: url($0["folder"])) }),
            CommandAction(id: "open_file", description: "Open a file in its app", risk: .safe, symbol: "arrow.up.forward.app",
                          parameters: [file], summary: { "Open \($0["file"]?.label ?? "file")" },
                          perform: { NSWorkspace.shared.open(url($0["file"])) }),
            CommandAction(id: "preview_file", description: "Preview a file (Quick Look)", risk: .safe, symbol: "eye",
                          parameters: [file], summary: { "Preview \($0["file"]?.label ?? "file")" },
                          perform: { QuickLookPanel.show([url($0["file"])]) }),
            CommandAction(id: "reveal_file", description: "Show a file in Finder", risk: .safe, symbol: "folder",
                          parameters: [file], summary: { "Show \($0["file"]?.label ?? "file") in Finder" },
                          perform: { NSWorkspace.shared.activateFileViewerSelecting([url($0["file"])]) }),
            CommandAction(id: "open_folder", description: "Open a folder in Finder", risk: .safe, symbol: "folder",
                          parameters: [folder], summary: { "Open \($0["folder"]?.label ?? "folder")" },
                          perform: { NSWorkspace.shared.open(url($0["folder"])) }),
        ]
        return NotchCommands(items: items, actions: actions)
    }

    /// Shelved files, files Claude Code just changed, then finished downloads (newest first).
    private var commandFiles: [(url: URL, kind: String, where: String)] {
        let shelved = shownItems.map { ($0, "File", "On the shelf") }
        let fromClaude = NotchBoard.shared.agentFiles.filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { ($0, "Claude changed", ProjectDrop.displayPath($0.deletingLastPathComponent(), project: nil)) }
        let downloaded = downloads.filter { !$0.isInProgress }.prefix(20)
            .map { ($0.url, "Download", "Downloaded " + $0.date.formatted(.relative(presentation: .named))) }
        var seen = Set<URL>()
        return (shelved + fromClaude + downloaded).filter { seen.insert($0.0).inserted }
    }
}
