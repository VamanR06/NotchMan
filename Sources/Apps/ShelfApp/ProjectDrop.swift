import Foundation

/// Putting dropped files into a Claude Code project: which folders to offer, where a file lands, and the
/// `@path` reference to paste into the session.
enum ProjectDrop {
    /// Folders not worth browsing into (besides hidden ones).
    static let skipped: Set<String> = [".git", "node_modules", "build", ".build", "dist", "DerivedData", "Pods", ".venv",
                                       "venv", "__pycache__", "target", ".next"]

    /// Subfolders to offer, alphabetical.
    static func subfolders(of folder: URL, fileManager: FileManager = .default) -> [URL] {
        let contents = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                                                             options: [.skipsHiddenFiles])) ?? []
        return contents.filter { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            return values?.isDirectory == true && values?.isPackage != true && !skipped.contains(url.lastPathComponent)
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
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
