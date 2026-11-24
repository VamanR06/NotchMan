import Foundation

/// Claude Code asks "Do you trust the files in this folder?" the first time it runs somewhere. A folder you pick for
/// a new agent is one you've already said you trust, so NotchMan records that answer in `~/.claude.json` the way
/// Claude Code does (`projects[<folder>].hasTrustDialogAccepted`) and the agent starts without asking.
enum ClaudeTrust {
    static var configURL: URL {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir).appending(path: ".claude.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude.json")
    }

    /// Marks `folder` trusted. Quietly does nothing when the config can't be read as JSON (Claude Code will just ask).
    static func trust(_ folder: String, config: URL = configURL) {
        let data = (try? Data(contentsOf: config)) ?? Data("{}".utf8)
        guard let updated = trusting(folder, in: data) else { return }
        // Written beside it and moved into place, as Claude Code does, so a running claude never reads half a file.
        try? updated.write(to: config, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
    }

    /// The config with `folder` trusted, or nil when nothing needs to change (already trusted, or not JSON).
    static func trusting(_ folder: String, in data: Data) -> Data? {
        guard var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let path = URL(fileURLWithPath: folder).standardizedFileURL.path
        var projects = root["projects"] as? [String: Any] ?? [:]
        if isTrusted(path, projects: projects) { return nil }
        var project = projects[path] as? [String: Any] ?? [:]
        project["hasTrustDialogAccepted"] = true
        projects[path] = project
        root["projects"] = projects
        return try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes])
    }

    /// Claude Code treats a folder as trusted when it, or any folder above it, was trusted.
    static func isTrusted(_ path: String, projects: [String: Any]) -> Bool {
        var url = URL(fileURLWithPath: path)
        while true {
            if (projects[url.path] as? [String: Any])?["hasTrustDialogAccepted"] as? Bool == true { return true }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return false }
            url = parent
        }
    }
}
