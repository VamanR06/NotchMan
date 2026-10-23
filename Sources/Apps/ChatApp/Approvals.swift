import Foundation
import NotchKit

/// A Claude Code tool call waiting for permission, received from its PermissionRequest hook.
struct ApprovalRequest: Identifiable, Equatable {
    let id: String
    let sessionID: String
    let cwd: String
    let toolName: String
    /// What it wants to do, in one line: the command, the file, the URL.
    let summary: String
    /// Why it deserves a second look, when an explicit rule matches (never a reason to act on its own).
    let risk: String?
    let received: Date

    var project: String { (cwd as NSString).lastPathComponent }

    /// Decodes the hook's JSON input (session_id, cwd, tool_name, tool_input, tool_use_id).
    static func decode(_ data: Data, now: Date = Date()) -> ApprovalRequest? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let session = json["session_id"] as? String,
              let tool = json["tool_name"] as? String else { return nil }
        let input = json["tool_input"] as? [String: Any] ?? [:]
        let cwd = json["cwd"] as? String ?? NSHomeDirectory()
        return ApprovalRequest(id: json["tool_use_id"] as? String ?? UUID().uuidString, sessionID: session, cwd: cwd,
                               toolName: tool, summary: summarize(tool: tool, input: input, cwd: cwd),
                               risk: risk(tool: tool, input: input, cwd: cwd), received: now)
    }

    static func summarize(tool: String, input: [String: Any], cwd: String) -> String {
        func string(_ key: String) -> String? { (input[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let text: String
        switch tool {
        case "Bash": text = string("command") ?? "a command"
        case "Edit", "Write", "MultiEdit", "NotebookEdit", "Read":
            text = (string("file_path") ?? string("notebook_path")).map { relative($0, to: cwd) } ?? "a file"
        case "WebFetch": text = string("url") ?? "a page"
        case "WebSearch": text = string("query").map { "“\($0)”" } ?? "the web"
        default:
            text = string("command") ?? string("file_path") ?? string("url") ?? string("description") ?? tool
        }
        let line = text.replacingOccurrences(of: "\n", with: " ⏎ ")
        return line.count > 240 ? String(line.prefix(240)) + "…" : line
    }

    static func relative(_ path: String, to cwd: String) -> String {
        let base = cwd.hasSuffix("/") ? cwd : cwd + "/"
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }

    /// Plain rules for things worth reading twice. They only change how the card looks.
    static func risk(tool: String, input: [String: Any], cwd: String) -> String? {
        switch tool {
        case "Bash":
            let command = (input["command"] as? String ?? "").lowercased()
            let rules: [(String, String)] = [
                (#"\brm\s+(-[a-z]*r[a-z]*f|-[a-z]*f[a-z]*r)\b"#, "deletes files recursively"),
                (#"\bsudo\b"#, "runs as administrator"),
                (#"\bgit\s+push\b.*(--force|-f\b)"#, "force-pushes"),
                (#"\bgit\s+(reset\s+--hard|clean\s+-[a-z]*f)"#, "discards local changes"),
                (#"(curl|wget)[^|]*\|\s*(sh|bash|zsh)\b"#, "runs a downloaded script"),
                (#"\b(mkfs|dd\s+if=|diskutil\s+erase)"#, "touches disks"),
                (#"\bchmod\s+(-r\s+)?777\b"#, "opens permissions to everyone"),
            ]
            return rules.first { command.range(of: $0.0, options: .regularExpression) != nil }?.1
        case "Edit", "Write", "MultiEdit":
            guard let path = input["file_path"] as? String else { return nil }
            let base = cwd.hasSuffix("/") ? cwd : cwd + "/"
            return path.hasPrefix(base) ? nil : "writes outside the project"
        default:
            return nil
        }
    }
}

enum ApprovalDecision: Equatable {
    case allow, deny
    /// No decision: Claude Code asks in its terminal as usual.
    case terminal
}

/// Installing and answering NotchMan's PermissionRequest hook (an HTTP hook to `HookServer`).
enum ApprovalHook {
    static var url: String { "http://127.0.0.1:\(HookServer.port)/permission" }
    static var settingsFile: URL { URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".claude/settings.json") }

    /// The hook's JSON answer, or nil for no decision.
    static func output(_ decision: ApprovalDecision) -> [String: Any]? {
        let behavior: String
        switch decision {
        case .allow: behavior = "allow"
        case .deny: behavior = "deny"
        case .terminal: return nil
        }
        var body: [String: Any] = ["behavior": behavior]
        if decision == .deny { body["message"] = "Denied from NotchMan" }
        return ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": body]]
    }

    static func entry(token: String, timeout: Int) -> [String: Any] {
        ["hooks": [["type": "http", "url": url, "timeout": timeout, "headers": ["Authorization": "Bearer \(token)"]]]]
    }

    /// `settings` with NotchMan's hook added (replacing an older copy), leaving every other hook alone.
    static func installing(into settings: [String: Any], token: String, timeout: Int) -> [String: Any] {
        var settings = removing(from: settings)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var permission = hooks["PermissionRequest"] as? [[String: Any]] ?? []
        permission.append(entry(token: token, timeout: timeout))
        hooks["PermissionRequest"] = permission
        settings["hooks"] = hooks
        return settings
    }

    /// `settings` without NotchMan's hook (and without the event key if nothing else is left there).
    static func removing(from settings: [String: Any]) -> [String: Any] {
        var settings = settings
        guard var hooks = settings["hooks"] as? [String: Any],
              let permission = hooks["PermissionRequest"] as? [[String: Any]] else { return settings }
        let kept = permission.filter { !isOurs($0) }
        hooks["PermissionRequest"] = kept.isEmpty ? nil : kept
        settings["hooks"] = hooks
        return settings
    }

    static func isInstalled(in settings: [String: Any]) -> Bool {
        ((settings["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]] ?? []).contains(where: isOurs)
    }

    private static func isOurs(_ group: [String: Any]) -> Bool {
        (group["hooks"] as? [[String: Any]] ?? []).contains { $0["url"] as? String == url }
    }

    // MARK: - File

    static func readSettings() -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsFile) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Writes `settings` after backing up the current file to settings.json.notchman-backup.
    static func writeSettings(_ settings: [String: Any]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: settingsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: settingsFile.path) {
            let backup = settingsFile.appendingPathExtension("notchman-backup")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: settingsFile, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys])
        try data.write(to: settingsFile, options: .atomic)
    }
}
