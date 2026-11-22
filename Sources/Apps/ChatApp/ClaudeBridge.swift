import Foundation

/// The NotchMan bridge: a Claude Code mod (a plugin with a hooks module) that tells NotchMan what each session is
/// doing — what you asked, each tool it uses and the file it touches, when a turn ends — so the Agents app can show
/// it, the notch can open to it, and the Shelf and command bar can offer the files it changed.
///
/// It only posts to NotchMan on 127.0.0.1 with NotchMan's secret token, never blocks or changes anything Claude does,
/// and stays quiet when NotchMan isn't running. Installing writes it to Application Support and adds that folder to
/// `CLAUDE_CODE_PLUGIN_DIRS` in `~/.claude/settings.json` (backed up first), which loads it in every session.
enum ClaudeBridge {
    static let pluginName = "notchman-bridge"
    static let pluginDirsKey = "CLAUDE_CODE_PLUGIN_DIRS"

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "NotchMan/claude-bridge")
    }

    /// The plugin's files, relative path → contents.
    static let files: [String: String] = [
        ".claude-plugin/plugin.json": """
        {
          "name": "\(pluginName)",
          "version": "1.0.0",
          "description": "Tells NotchMan (the notch app on this Mac) what this session is doing.",
          "author": { "name": "NotchMan" }
        }

        """,
        "hooks/hooks.json": """
        {
          "modules": ["./register.js"]
        }

        """,
        "hooks/register.js": #"""
        // Tells NotchMan, the notch app on this Mac, what this session is doing: what you asked, each tool Claude uses
        // and the file it touches, and when a turn ends. Every hook passes the event on unchanged and posts in the
        // background, so nothing here waits on NotchMan or changes what Claude does. It only talks to 127.0.0.1, with
        // NotchMan's own secret token, and stays quiet when NotchMan isn't running.

        const ENDPOINT = 'http://127.0.0.1:43822/session-signal'
        let token = null

        async function send($, signal) {
          try {
            if (token === null) {
              const home = await $.env.get('HOME')
              token = String(await $.fs.read(home + '/Library/Application Support/NotchMan/hook-token')).trim()
            }
            const session = await $.session.id()
            const cwd = await $.session.cwd()
            await $.http.fetch(ENDPOINT, {
              method: 'POST',
              headers: { 'content-type': 'application/json', authorization: 'Bearer ' + token },
              body: JSON.stringify({ ...signal, session, cwd }),
            })
          } catch (error) {
            // NotchMan isn't running, or its token changed: read the token again next time.
            token = null
          }
        }

        function clip(value, length) {
          return typeof value === 'string' ? value.slice(0, length) : null
        }

        export function register(on) {
          on('prompt.submit', async ($, e, next) => {
            send($, { event: 'prompt', text: clip(e.text, 300) })
            return next(e)
          })

          on('tool.call', async ($, e, next) => {
            send($, {
              event: 'tool',
              tool: e.tool,
              file: clip(e.file_path ?? e.notebook_path, 1000),
              command: clip(e.command, 200),
              description: clip(e.description, 200),
            })
            return next(e)
          })

          on('turn.complete', async ($, e, next) => {
            // The main conversation's turns only, not subagents'.
            if (e.agentId === undefined) send($, { event: 'turn.complete', aborted: !!e.isAborted })
            return next(e)
          })
        }

        """#,
    ]

    // MARK: Install

    static func isInstalled(settings: [String: Any] = ApprovalHook.readSettings(), folder: URL = folder) -> Bool {
        pluginDirs(in: settings).contains(folder.path)
            && FileManager.default.fileExists(atPath: folder.appending(path: "hooks/register.js").path)
    }

    static func install() throws {
        try writeFiles(to: folder)
        try ApprovalHook.writeSettings(installing(into: ApprovalHook.readSettings(), folder: folder))
    }

    static func uninstall() throws {
        try ApprovalHook.writeSettings(removing(from: ApprovalHook.readSettings(), folder: folder))
        try? FileManager.default.removeItem(at: folder)
    }

    static func writeFiles(to folder: URL) throws {
        for (path, contents) in files {
            let url = folder.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// `settings` with the folder added to `env.CLAUDE_CODE_PLUGIN_DIRS`, keeping any other folders there.
    static func installing(into settings: [String: Any], folder: URL) -> [String: Any] {
        var dirs = pluginDirs(in: settings)
        if !dirs.contains(folder.path) { dirs.append(folder.path) }
        return setting(dirs, in: settings)
    }

    /// `settings` without the folder (and without the variable or `env` if nothing else is left in them).
    static func removing(from settings: [String: Any], folder: URL) -> [String: Any] {
        setting(pluginDirs(in: settings).filter { $0 != folder.path }, in: settings)
    }

    static func pluginDirs(in settings: [String: Any]) -> [String] {
        let value = (settings["env"] as? [String: Any])?[pluginDirsKey] as? String ?? ""
        return value.split(separator: ":").map(String.init).filter { !$0.isEmpty }
    }

    private static func setting(_ dirs: [String], in settings: [String: Any]) -> [String: Any] {
        var settings = settings
        var env = settings["env"] as? [String: Any] ?? [:]
        env[pluginDirsKey] = dirs.isEmpty ? nil : dirs.joined(separator: ":")
        settings["env"] = env.isEmpty ? nil : env
        return settings
    }
}
