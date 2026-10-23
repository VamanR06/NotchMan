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

    struct Browsing: Equatable {
        let project: BoardProject
        var folder: URL
        var root: URL { URL(fileURLWithPath: project.cwd) }
    }

    struct ProjectDropResult: Equatable {
        let project: BoardProject
        let files: [URL]
        let references: String
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

    // MARK: - Projects

    func browse(_ project: BoardProject) {
        browsing = Browsing(project: project, folder: URL(fileURLWithPath: project.cwd))
    }

    func open(folder: URL) {
        browsing?.folder = folder
    }

    func up() {
        guard let browsing else { return }
        if browsing.folder.standardizedFileURL.path == browsing.root.standardizedFileURL.path {
            self.browsing = nil
        } else {
            self.browsing?.folder = browsing.folder.deletingLastPathComponent()
        }
    }

    /// Copies `urls` into `folder` of `project` (⌥ held: moves), asking before replacing anything; then copies
    /// the `@path` references for the session.
    func drop(_ urls: [URL], into folder: URL, of project: BoardProject) {
        let move = moveFiles != NSEvent.modifierFlags.contains(.option)
        let fm = FileManager.default
        var placed: [URL] = []
        for source in urls {
            var (target, exists) = ProjectDrop.target(for: source, in: folder)
            if source.standardizedFileURL == target.standardizedFileURL { placed.append(target); continue }
            if ProjectDrop.isInside(folder, source) {
                context?.showTransient(NotchTransient(id: "shelf", systemImage: "exclamationmark.triangle.fill",
                                                      text: "Can't go inside itself", tint: .orange, duration: 2.5))
                continue
            }
            if exists {
                switch askAboutConflict(name: target.lastPathComponent, folder: ProjectDrop.label(for: folder, in: URL(fileURLWithPath: project.cwd))) {
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
                context?.showTransient(NotchTransient(id: "shelf", systemImage: "exclamationmark.triangle.fill",
                                                      text: "Couldn't add", tint: .orange, duration: 2.5))
            }
        }
        folderRevision += 1
        guard !placed.isEmpty else { return }
        let root = URL(fileURLWithPath: project.cwd)
        let references = placed.map { ProjectDrop.reference(for: $0, in: root) }.joined(separator: " ")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(references, forType: .string)
        lastDrop = ProjectDropResult(project: project, files: placed, references: references)
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
        guard let drop = lastDrop else { return }
        if NotchBoard.shared.insertIntoSession?(drop.project, drop.references + " ") == true {
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
