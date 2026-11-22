import AppKit
import NotchKit

/// The generated notch apps: one folder each (`manifest.json` + `app.js`) under
/// `~/Library/Application Support/NotchMan/mods`. Keeps the dock in step with the folder — a new app appears, a changed
/// one reloads, a deleted one goes — and offers "Make a notch app" in the command bar.
@MainActor
public final class ModLibrary {
    public static var defaultFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "NotchMan/mods")
    }

    public let folder: URL
    private let generator: ModGenerator
    private let add: (any NotchApp) -> Void
    private let remove: (String) -> Void
    private let reveal: (String) -> Void
    private(set) var apps: [String: (app: ModApp, modified: Date)] = [:]
    private var watcher: DirectoryWatcher?

    public init(folder: URL = ModLibrary.defaultFolder, generator: ModGenerator = ModGenerator(),
                add: @escaping (any NotchApp) -> Void, remove: @escaping (String) -> Void,
                reveal: @escaping (String) -> Void) {
        self.folder = folder
        self.generator = generator
        self.add = add
        self.remove = remove
        self.reveal = reveal
    }

    public func start() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        scan()
        watcher = DirectoryWatcher(paths: [folder.path]) { [weak self] in self?.scan() }
    }

    /// Brings the dock in line with the folders.
    func scan() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                                    options: [.skipsHiddenFiles])) ?? []
        var seen = Set<String>()
        for appFolder in folders {
            let manifestURL = appFolder.appending(path: "manifest.json"), scriptURL = appFolder.appending(path: "app.js")
            guard let manifestData = try? Data(contentsOf: manifestURL),
                  let script = try? String(contentsOf: scriptURL, encoding: .utf8),
                  let manifest = try? ModManifest.decode(manifestData) else { continue }
            let key = appFolder.lastPathComponent
            seen.insert(key)
            let modified = [manifestURL, scriptURL].compactMap {
                (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            }.max() ?? .distantPast
            if let existing = apps[key] {
                if modified > existing.modified {
                    existing.app.load(manifest: manifest, script: script)
                    apps[key] = (existing.app, modified)
                }
            } else {
                let app = ModApp(folder: appFolder, manifest: manifest, script: script)
                app.change = { [weak self] request in try await self?.generator.change(appFolder, request) }
                app.remove = { [weak self] in self?.trash(key) }
                apps[key] = (app, modified)
                add(app)
            }
        }
        for key in apps.keys where !seen.contains(key) {
            if let gone = apps.removeValue(forKey: key) { remove(gone.app.id) }
        }
    }

    private func trash(_ key: String) {
        guard let entry = apps[key] else { return }
        try? FileManager.default.trashItem(at: entry.app.folder, resultingItemURL: nil)
        apps.removeValue(forKey: key)
        remove(entry.app.id)
    }

    /// Makes a new app for `request`, adds it to the dock and shows it.
    func make(_ request: String) async throws -> String {
        let appFolder = try await generator.make(request, in: folder)
        scan()
        guard let app = apps[appFolder.lastPathComponent]?.app else { return "Made it, but it didn't load — see \(appFolder.path)." }
        reveal(app.id)
        return "Added \(app.name) to the dock. Use its ⋯ menu to change it with Claude."
    }

    /// The command bar: "Make a notch app: …" for any request of a few words, and each app by name.
    public func commands(for query: String) -> NotchCommands {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard text.split(whereSeparator: \.isWhitespace).count >= 2 else { return .none }
        let make = CommandItem(id: "mods.make", title: "Make a notch app: “\(text)”",
                               subtitle: "Claude writes a small app for the notch (about a minute)", symbol: "wand.and.stars",
                               kind: "New app", answer: { [weak self] in
            guard let self else { return "" }
            return try await self.make(text)
        })
        return NotchCommands(fallbacks: [make])
    }
}
