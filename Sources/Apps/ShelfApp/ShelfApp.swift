import AppKit
import SwiftUI
import NotchKit

/// Somewhere to put files for a moment: drag files onto the notch to keep them on the shelf, or drop them into
/// an active Claude Code project's folder to reference in the session. Also shows recent downloads and commands
/// wrapped in `notchman-run`.
@MainActor @Observable
public final class ShelfApp: NotchApp {
    public let id = "shelf"
    public let name = "Shelf"
    public let iconSystemName = "tray.full"
    public var expandedHeight: CGFloat { 210 }
    public var acceptsFileDrags: Bool { true }

    enum Tab: String { case shelf, downloads }
    var tab: Tab = .shelf

    private(set) var items: [URL] = []
    private(set) var downloads: [DownloadItem] = []
    private(set) var commands: [RunningCommand] = []
    /// The project folder open in the drop browser.
    var browsing: Browsing?
    /// The last drop into a project, offered for "Insert in session".
    private(set) var lastDrop: ProjectDropResult?
    private(set) var runInstalled = NotchmanRun.isInstalled
    /// Dropping into a project moves files instead of copying them (⌥ while dropping does the other one).
    var moveFiles = false {
        didSet { context?.defaults.set(moveFiles, forKey: "moveFiles") }
    }
    /// Bumped when the open folder's contents change, so the browser re-lists it.
    private(set) var folderRevision = 0

    /// The folder open in the drop browser. Browsing starts somewhere (a project, a place, a recent folder) and
    /// can go anywhere from there.
    struct Browsing: Equatable {
        var folder: URL
        /// The Claude Code project the folder is in, if any (for labels and `@path` references).
        var project: BoardProject?
        var root: URL? { project.map { URL(fileURLWithPath: $0.cwd) } }
    }

    struct ProjectDropResult: Equatable {
        /// Set when the folder is inside a Claude Code project: then `references` holds the `@path`s.
        let project: BoardProject?
        let folder: URL
        let files: [URL]
        let references: String?
        var inserted = false
    }

    var projects: [BoardProject] { NotchBoard.shared.projects }

    @ObservationIgnored private var context: NotchContext?
    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private var progressToken: Any?
    @ObservationIgnored private var progresses: [String: Progress] = [:]
    @ObservationIgnored private var poll: Task<Void, Never>?

    public init() {}

    public func activate(context: NotchContext) {
        self.context = context
        items = (context.defaults.array(forKey: "shelf") as? [Data] ?? []).compactMap(Self.resolve)
        moveFiles = context.defaults.bool(forKey: "moveFiles")
        refreshDownloads()
        watcher = DirectoryWatcher(paths: [DownloadsFolder.url.path]) { [weak self] in self?.refreshDownloads() }
        watchProgress()
        HookServer.shared.route("/progress") { [weak self] request in
            let json = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
            let id = json["id"] as? String, title = json["title"] as? String, state = json["state"] as? String
            let exit = json["exitCode"] as? Int
            await MainActor.run { self?.commandUpdate(id: id, title: title, state: state, exitCode: exit) }
            return .empty
        }
    }

    public func deactivate() {
        poll?.cancel()
        if let progressToken { Progress.removeSubscriber(progressToken) }
    }

    // MARK: - Shelf

    func addToShelf(_ urls: [URL]) {
        let new = urls.filter { !items.contains($0) }
        guard !new.isEmpty else { return }
        items.append(contentsOf: new)
        save()
        tab = .shelf
    }

    func remove(_ url: URL) {
        items.removeAll { $0 == url }
        save()
    }

    func clearShelf() {
        items.removeAll()
        save()
    }

    /// Files that were moved or deleted since being shelved drop off.
    func pruneMissing() {
        let existing = items.filter { FileManager.default.fileExists(atPath: $0.path) }
        if existing.count != items.count {
            items = existing
            save()
        }
    }

    func airDrop(_ urls: [URL]) {
        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: urls)
    }

    private func save() {
        context?.defaults.set(items.compactMap { try? $0.bookmarkData() }, forKey: "shelf")
    }

    private static func resolve(_ data: Data) -> URL? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    // MARK: - Folders

    func browse(_ project: BoardProject) {
        browse(URL(fileURLWithPath: project.cwd))
    }

    /// Opens the drop browser at `folder`.
    func browse(_ folder: URL) {
        browsing = Browsing(folder: folder, project: project(containing: folder))
    }

    func open(folder: URL) {
        browsing = Browsing(folder: folder, project: project(containing: folder))
    }

    /// The parent folder (stopping at the top of the disk).
    func up() {
        guard let folder = browsing?.folder, folder.path != "/" else { return }
        open(folder: folder.deletingLastPathComponent())
    }

    func closeBrowser() {
        browsing = nil
    }

    /// Picks any folder on the Mac to start browsing from.
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.directoryURL = browsing?.folder ?? recentFolders.first ?? FileManager.default.homeDirectoryForCurrentUser
        context?.holdOpen(true)
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url { browse(url) }
        context?.holdOpen(false)
    }

    /// The running Claude Code project `url` is in (the deepest, when projects nest).
    func project(containing url: URL) -> BoardProject? {
        let path = url.standardizedFileURL.path
        return projects
            .filter { path == $0.cwd || path.hasPrefix($0.cwd.hasSuffix("/") ? $0.cwd : $0.cwd + "/") }
            .max { $0.cwd.count < $1.cwd.count }
    }

    /// Folders to start from besides projects and recents.
    static var places: [(name: String, symbol: String, url: URL)] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        return [
            ("Home", "house", home),
            ("Desktop", "menubar.dock.rectangle", fm.urls(for: .desktopDirectory, in: .userDomainMask)[0]),
            ("Documents", "doc", fm.urls(for: .documentDirectory, in: .userDomainMask)[0]),
            ("Downloads", "arrow.down.circle", fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0]),
        ].filter { fm.fileExists(atPath: $0.2.path) }
    }

    // MARK: Recents

    /// Folders files were last dropped into, newest first (only ones that still exist).
    var recentFolders: [URL] {
        _ = recentRevision
        return RecentFolders.load(context?.defaults).filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private var recentRevision = 0

    private func remember(_ folder: URL) {
        RecentFolders.add(folder, to: context?.defaults)
        recentRevision += 1
    }

    func forgetRecent(_ folder: URL) {
        RecentFolders.remove(folder, from: context?.defaults)
        recentRevision += 1
    }

    /// Copies `urls` into `folder` (⌥ held: the other of Copy/Move), asking before replacing anything. Inside a
    /// Claude Code project the `@path` references are copied for the session.
    func drop(_ urls: [URL], into folder: URL) {
        let project = project(containing: folder)
        let chosenMove = moveFiles != NSEvent.modifierFlags.contains(.option)
        let fm = FileManager.default
        var placed: [URL] = []
        for source in urls {
            // Dragged-in contents (not a file on disk) were saved to the holding folder: always move those.
            let move = chosenMove || source.path.hasPrefix(DroppedItems.holdingFolder.path)
            var (target, exists) = ProjectDrop.target(for: source, in: folder)
            if source.standardizedFileURL == target.standardizedFileURL { placed.append(target); continue }
            if ProjectDrop.isInside(folder, source) {
                context?.showTransient(NotchTransient(id: "shelf", systemImage: "exclamationmark.triangle.fill",
                                                      text: "Can't go inside itself", tint: .orange, duration: 2.5))
                continue
            }
            if exists {
                let place = project.map { ProjectDrop.label(for: folder, in: URL(fileURLWithPath: $0.cwd)) } ?? folder.lastPathComponent
                switch askAboutConflict(name: target.lastPathComponent, folder: place) {
                case .replace:
                    try? fm.trashItem(at: target, resultingItemURL: nil)
                case .keepBoth:
                    target = ProjectDrop.freeName(for: target)
                case .skip:
                    continue
                }
            }
            do {
                if move { try fm.moveItem(at: source, to: target) } else { try fm.copyItem(at: source, to: target) }
                placed.append(target)
                if move { remove(source) }
            } catch {
                context?.logger.error("Couldn't \(move ? "move" : "copy", privacy: .public) \(source.lastPathComponent, privacy: .public) to \(folder.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                context?.showTransient(NotchTransient(id: "shelf", systemImage: "exclamationmark.triangle.fill",
                                                      text: "Couldn't add", tint: .orange, duration: 2.5))
            }
        }
        folderRevision += 1
        guard !placed.isEmpty else { return }
        remember(folder)
        guard let project else {
            lastDrop = ProjectDropResult(project: nil, folder: folder, files: placed, references: nil)
            context?.showTransient(NotchTransient(id: "shelf", systemImage: "checkmark.circle.fill",
                                                  text: chosenMove ? "Moved" : "Added", tint: .green, duration: 2))
            return
        }
        let root = URL(fileURLWithPath: project.cwd)
        let references = placed.map { ProjectDrop.reference(for: $0, in: root) }.joined(separator: " ")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(references, forType: .string)
        lastDrop = ProjectDropResult(project: project, folder: folder, files: placed, references: references)
        context?.showTransient(NotchTransient(id: "shelf", systemImage: "checkmark.circle.fill",
                                              text: "@ copied", tint: .green, duration: 2))
    }

    /// Makes a folder in the folder being browsed ("name 2" if taken) and opens it, ready for a drop.
    @discardableResult
    func createFolder(named typed: String) -> Bool {
        guard let browsing, let name = ProjectDrop.folderName(typed) else { return false }
        let url = ProjectDrop.freeName(for: browsing.folder.appending(path: name))
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            folderRevision += 1
            self.browsing?.folder = url
            return true
        } catch {
            context?.showTransient(NotchTransient(id: "shelf", systemImage: "exclamationmark.triangle.fill",
                                                  text: "Couldn't create", tint: .orange, duration: 2.5))
            return false
        }
    }

    /// Keeps the notch open while a folder name is being typed.
    func setTyping(_ typing: Bool) {
        context?.holdOpen(typing)
    }

    /// Types the last drop's references into the project's notch terminal (without Return).
    func insertLastDrop() {
        guard let drop = lastDrop, let project = drop.project, let references = drop.references else { return }
        if NotchBoard.shared.insertIntoSession?(project, references + " ") == true {
            lastDrop?.inserted = true
        }
    }

    func canInsert(into project: BoardProject) -> Bool { project.agentID != nil }

    func dismissLastDrop() { lastDrop = nil }

    enum ConflictChoice { case replace, keepBoth, skip }

    private func askAboutConflict(name: String, folder: String) -> ConflictChoice {
        let alert = NSAlert()
        alert.messageText = "“\(name)” already exists in \(folder)"
        alert.informativeText = "Replace it (the old one goes to the Trash), or keep both?"
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Skip")
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .keepBoth
        case .alertSecondButtonReturn: return .replace
        default: return .skip
        }
    }

    // MARK: - Downloads

    private func refreshDownloads() {
        let before = downloads
        var fresh = DownloadsFolder.list()
        for index in fresh.indices where fresh[index].isInProgress {
            fresh[index].fraction = progresses[fresh[index].url.path].map(\.fractionCompleted)
        }
        downloads = fresh
        // Something that was arriving is now there under its final name: say so.
        let finished = before.filter(\.isInProgress).filter { old in
            !fresh.contains { $0.url == old.url } && fresh.contains { !$0.isInProgress && $0.name == old.name }
        }
        if let done = finished.first {
            context?.showTransient(NotchTransient(id: "download", systemImage: "arrow.down.circle.fill",
                                                  text: done.name, tint: .green, duration: 2.5))
        }
        updatePolling()
    }

    /// Safari and Finder publish progress for files they're writing; subscribe for the Downloads folder.
    private func watchProgress() {
        progressToken = Self.subscribeToDownloads { [weak self] path, box in
            Task { @MainActor in
                if let path { self?.progresses[path] = box.progress }
                self?.refreshDownloads()
            }
        }
    }

    /// Carries a Progress across threads (it's thread-safe; it just isn't marked Sendable).
    private final class ProgressBox: @unchecked Sendable {
        let progress: Progress?
        init(_ progress: Progress?) { self.progress = progress }
    }

    /// Foundation calls these handlers on its own threads, so they're built outside the main actor and only pass
    /// what changed along (nil progress = finished).
    nonisolated private static func subscribeToDownloads(
        _ changed: @escaping @Sendable (String?, ProgressBox) -> Void
    ) -> Any {
        Progress.addSubscriber(forFileURL: DownloadsFolder.url) { progress in
            let path = progress.fileURL?.path
            changed(path, ProgressBox(progress))
            return { changed(path, ProgressBox(nil)) }
        }
    }

    /// Re-reads sizes and fractions twice a second while anything is downloading.
    private func updatePolling() {
        let active = downloads.contains(where: \.isInProgress)
        if active, poll == nil {
            poll = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    self?.refreshDownloads()
                }
            }
        } else if !active {
            poll?.cancel()
            poll = nil
        }
    }

    var activeDownloads: [DownloadItem] { downloads.filter(\.isInProgress) }

    // MARK: - Commands (notchman-run)

    private func commandUpdate(id: String?, title: String?, state: String?, exitCode: Int?) {
        guard let id else { return }
        let title = title?.isEmpty == false ? title! : "Command"
        switch state {
        case "start":
            commands.append(RunningCommand(id: id, title: title, started: Date()))
        case "done":
            let command = commands.first { $0.id == id }
            commands.removeAll { $0.id == id }
            let ok = (exitCode ?? 0) == 0
            let took = command.map { Date().timeIntervalSince($0.started) } ?? 0
            context?.showTransient(NotchTransient(id: "command:\(id)", systemImage: ok ? "checkmark.circle.fill" : "xmark.octagon.fill",
                                                  text: ok ? "Done" : "Failed", tint: ok ? .green : .red, duration: 2.5))
            context?.requestAttention(.pulse)
            // Long ones also notify, since you've probably looked away.
            if took > 10 {
                context?.notify(title: ok ? "✓ \(title)" : "✗ \(title)",
                                body: ok ? "Finished in \(Int(took))s" : "Exited with status \(exitCode ?? 1)")
            }
        default:
            break
        }
    }

    func installRun() {
        do {
            try NotchmanRun.install()
            runInstalled = true
        } catch {
            context?.showTransient(NotchTransient(id: "shelf", systemImage: "exclamationmark.triangle.fill",
                                                  text: "Not installed", tint: .orange, duration: 2.5))
        }
    }

    // MARK: - NotchApp

    public var activity: NotchActivity? {
        if let download = activeDownloads.first {
            let text = download.fraction.map { "\(Int($0 * 100))%" } ?? "↓"
            return NotchActivity(priority: 16) { NotchChip(text) { NotchSpinner(size: 11, lineWidth: 1.8) } }
        }
        if let command = commands.first {
            let text = commands.count > 1 ? "\(commands.count) running" : String(command.title.prefix(10))
            return NotchActivity(priority: 15) { NotchChip(text) { NotchSpinner(size: 11, lineWidth: 1.8) } }
        }
        if !items.isEmpty {
            return NotchActivity(priority: 1) { NotchChip("\(items.count)", systemImage: "tray.full.fill") }
        }
        return nil
    }

    public var dockBadge: NotchBadge? {
        activeDownloads.isEmpty && commands.isEmpty ? nil : .busy
    }

    public func makeExpandedView() -> AnyView {
        AnyView(ShelfView(app: self))
    }

    public func makeSettingsView() -> AnyView? {
        AnyView(ShelfSettingsView(app: self))
    }
}
