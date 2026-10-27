import Foundation

/// Putting dropped files into a Claude Code project: which folders to offer, where a file lands, and the
/// `@path` reference to paste into the session.
enum ProjectDrop {
    /// Folders not worth browsing into (besides hidden ones).
    static let skipped: Set<String> = [".git", "node_modules", "build", ".build", "dist", "DerivedData", "Pods", ".venv",
                                       "venv", "__pycache__", "target", ".next"]

    /// Subfolders to offer, alphabetical.
    static func subfolders(of folder: URL, fileManager: FileManager = .default) -> [URL] {
        entries(of: folder, hidingBuildFolders: true, fileManager: fileManager).folders
    }

    /// A folder's contents for the browser: folders (to open and drop into) and files (to see where you are),
    /// alphabetical, hidden items left out. Inside projects, build and dependency folders are left out too.
    static func entries(of folder: URL, hidingBuildFolders: Bool, matching filter: String = "",
                        fileManager: FileManager = .default) -> (folders: [URL], files: [URL]) {
        let contents = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                                                             options: [.skipsHiddenFiles])) ?? []
        let needle = filter.trimmingCharacters(in: .whitespaces)
        var folders: [URL] = [], files: [URL] = []
        for url in contents {
            if !needle.isEmpty && !url.lastPathComponent.localizedCaseInsensitiveContains(needle) { continue }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            if values?.isDirectory == true && values?.isPackage != true {
                if !(hidingBuildFolders && skipped.contains(url.lastPathComponent)) { folders.append(url) }
            } else {
                files.append(url)
            }
        }
        let byName: (URL, URL) -> Bool = { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return (folders.sorted(by: byName), files.sorted(by: byName))
    }

    /// `folder` and the folders above it, nearest first (for jumping up from the path).
    static func ancestors(of folder: URL) -> [URL] {
        var out: [URL] = []
        var current = folder.standardizedFileURL
        while true {
            out.append(current)
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path || current.path == "/" { break }
            current = parent
        }
        return out
    }

    /// How a folder reads in the browser's path: relative to the project, else with the home folder as "~".
    static func displayPath(_ folder: URL, project: BoardProjectRef?) -> String {
        if let project, folder.path.hasPrefix(project.cwd) { return label(for: folder, in: URL(fileURLWithPath: project.cwd)) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = folder.standardizedFileURL.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// Where `source` would land in `folder`, and whether something is already there.
    static func target(for source: URL, in folder: URL, fileManager: FileManager = .default) -> (url: URL, exists: Bool) {
        let url = folder.appending(path: source.lastPathComponent)
        return (url, fileManager.fileExists(atPath: url.path))
    }

    /// "name 2.ext", "name 3.ext", … — the first free name, as Finder does.
    static func freeName(for url: URL, fileManager: FileManager = .default) -> URL {
        guard fileManager.fileExists(atPath: url.path) else { return url }
        let folder = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let stem = ext.isEmpty ? url.lastPathComponent : String(url.lastPathComponent.dropLast(ext.count + 1))
        var number = 2
        while true {
            let name = ext.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(ext)"
            let candidate = folder.appending(path: name)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            number += 1
        }
    }

    /// Whether `target` is `source` itself or inside it (a folder can't be copied or moved into itself).
    static func isInside(_ target: URL, _ source: URL) -> Bool {
        let source = source.standardizedFileURL.path
        let target = target.standardizedFileURL.path
        return target == source || target.hasPrefix(source.hasSuffix("/") ? source : source + "/")
    }

    /// A usable folder name from what was typed, or nil ("/" and ":" aren't allowed, nor "." or "..").
    static func folderName(_ typed: String) -> String? {
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains(":") else { return nil }
        return name
    }

    /// How a session refers to the file: `@src/assets/logo.png`, quoted when the path has spaces.
    static func reference(for file: URL, in project: URL) -> String {
        let root = project.standardizedFileURL.path
        let path = file.standardizedFileURL.path
        let base = root.hasSuffix("/") ? root : root + "/"
        let relative = path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
        return relative.contains(" ") ? "@\"\(relative)\"" : "@\(relative)"
    }

    /// The folder's path inside the project, for labels ("src/assets", or the project name at its root).
    static func label(for folder: URL, in project: URL) -> String {
        let root = project.standardizedFileURL.path
        let path = folder.standardizedFileURL.path
        guard path.count > root.count, path.hasPrefix(root) else { return project.lastPathComponent }
        return project.lastPathComponent + String(path.dropFirst(root.count))
    }
}

/// Just what `displayPath` needs from a project (keeps ProjectDrop free of NotchKit).
struct BoardProjectRef {
    let cwd: String
}

/// The folders files were last dropped into, newest first, kept in the app's preferences.
enum RecentFolders {
    static let key = "recentFolders"
    static let limit = 8

    static func load(_ defaults: UserDefaults?) -> [URL] {
        (defaults?.stringArray(forKey: key) ?? []).map { URL(fileURLWithPath: $0) }
    }

    static func add(_ folder: URL, to defaults: UserDefaults?) {
        let path = folder.standardizedFileURL.path
        var paths = defaults?.stringArray(forKey: key) ?? []
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        defaults?.set(Array(paths.prefix(limit)), forKey: key)
    }

    static func remove(_ folder: URL, from defaults: UserDefaults?) {
        let path = folder.standardizedFileURL.path
        defaults?.set((defaults?.stringArray(forKey: key) ?? []).filter { $0 != path }, forKey: key)
    }
}
