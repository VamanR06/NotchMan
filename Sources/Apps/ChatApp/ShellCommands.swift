import AppKit
import SwiftUI

/// Commands Claude mentions in its replies (`swift test`, a ```bash block) and running them: ⌘-click runs one in a
/// shell in the project folder, ⌥⌘-click in a new Terminal window.
enum ShellCommand {
    /// Programs a command line is likely to start with; anything else in backticks is a name, a path or code.
    static let programs: Set<String> = [
        "git", "gh", "swift", "swiftc", "xcodebuild", "xcrun", "xcode-select", "pod", "carthage", "fastlane",
        "npm", "npx", "yarn", "pnpm", "bun", "bunx", "deno", "node", "tsc", "vite", "next", "expo",
        "python", "python3", "pip", "pip3", "pipx", "uv", "uvx", "poetry", "pytest", "ruff", "black", "mypy",
        "brew", "make", "cmake", "ninja", "cargo", "rustup", "go", "java", "mvn", "gradle", "ruby", "gem", "bundle",
        "rake", "rails", "docker", "docker-compose", "kubectl", "helm", "terraform", "aws", "gcloud", "firebase",
        "supabase", "vercel", "netlify", "fly", "heroku", "claude", "codex", "cd", "ls", "cat", "less", "head",
        "tail", "grep", "rg", "find", "fd", "sed", "awk", "jq", "curl", "wget", "open", "mkdir", "touch", "cp", "mv",
        "rm", "chmod", "chown", "ln", "echo", "export", "source", "env", "which", "ps", "kill", "killall", "lsof",
        "ssh", "scp", "rsync", "tar", "zip", "unzip", "defaults", "launchctl", "plutil", "codesign", "spctl",
        "security", "sudo", "code", "cursor", "tree", "du", "df", "top", "htop", "diff", "patch", "pwd", "say",
        "osascript", "sqlite3", "psql", "mysql", "redis-cli", "ffmpeg", "tmux",
    ]

    /// Languages a fenced block of shell commands is labelled with.
    static let shellLanguages: Set<String> = ["bash", "sh", "zsh", "shell", "console", "terminal", "shell-session", "fish"]

    /// The command in inline code (`` `swift test` ``), or nil when it doesn't read as one.
    static func inline(_ code: String) -> String? {
        let line = stripPrompt(code.trimmingCharacters(in: .whitespaces))
        guard !line.isEmpty, !line.contains("\n"), startsWithProgram(line) else { return nil }
        // A bare word is a name more often than a command (`git`, `make`), unless it's one of these.
        return line.contains(" ") || ["ls", "pwd", "make", "swift test"].contains(line) ? line : nil
    }

    /// The commands in a fenced block, one per line, or nil when it isn't shell. In a `console` block only the
    /// lines after a `$` prompt are commands (the rest is output).
    static func block(_ code: String, language: String?) -> String? {
        let lines = code.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        let lang = language?.lowercased()
        let prompted = lines.filter { $0.hasPrefix("$ ") || $0.hasPrefix("% ") }
        let commands: [String]
        if lang.map(shellLanguages.contains) == true {
            commands = (prompted.isEmpty ? lines : prompted).map(stripPrompt).filter { !$0.hasPrefix("#") }
        } else if lang == nil {
            // An unlabelled block counts only when every line reads as a command.
            let candidates = (prompted.isEmpty ? lines : prompted).map(stripPrompt)
            guard candidates.allSatisfy({ startsWithProgram($0) || $0.hasPrefix("#") }) else { return nil }
            commands = candidates.filter { !$0.hasPrefix("#") }
        } else {
            return nil
        }
        return commands.isEmpty ? nil : commands.joined(separator: "\n")
    }

    static func startsWithProgram(_ line: String) -> Bool {
        if line.hasPrefix("./") || line.hasPrefix("~/") { return true }
        // `FOO=1 npm test` and `sudo make install` count by what follows.
        let words = line.split(separator: " ").map(String.init).drop { $0.contains("=") && !$0.hasPrefix("-") }
        guard let first = words.first else { return false }
        return programs.contains(first)
    }

    private static func stripPrompt(_ line: String) -> String {
        for prompt in ["$ ", "% ", "❯ "] where line.hasPrefix(prompt) {
            return String(line.dropFirst(prompt.count)).trimmingCharacters(in: .whitespaces)
        }
        return line
    }

    /// A `notchman-run:` link for a command, so a click in a reply's text can be told apart from a real link.
    static func link(for command: String) -> URL? {
        var components = URLComponents()
        components.scheme = "notchman-run"
        components.path = command
        return components.url
    }

    static func command(from url: URL) -> String? {
        guard url.scheme == "notchman-run" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.path
    }

    /// Opens a new Terminal window in `folder` running `command`, through a throwaway `.command` file (no
    /// automation permission needed). The window stays open at a shell afterwards.
    static func openInTerminal(_ command: String, in folder: String) {
        let script = """
        #!/bin/zsh -l
        cd \(Shell.quote(folder)) 2>/dev/null
        \(command)
        exec zsh -l
        """
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("notchman-\(UUID().uuidString.prefix(8)).command")
        do {
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            NSWorkspace.shared.open(file)
        } catch {
            NSSound.beep()
        }
    }

    static func copy(_ command: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }
}

/// What ⌘-click on a command in a reply does; set by the session view, absent elsewhere (commands stay plain text).
struct CommandRunner: Sendable {
    /// In a shell in the project folder, inside the notch.
    var run: @MainActor @Sendable (String) -> Void
    /// In a new Terminal window.
    var runInTerminal: @MainActor @Sendable (String) -> Void
    /// Saves it as one of the project's quick commands.
    var save: @MainActor @Sendable (String) -> Void = { _ in }

    /// ⌘-click runs, ⌥⌘-click runs in Terminal, a plain click copies.
    @MainActor func click(_ command: String) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) && flags.contains(.option) {
            runInTerminal(command)
        } else if flags.contains(.command) {
            run(command)
        } else {
            ShellCommand.copy(command)
        }
    }
}

extension EnvironmentValues {
    @Entry var commandRunner: CommandRunner?
}

/// Right-click on a command: run it here or in Terminal, copy it, or keep it as a quick command.
private struct CommandContextMenu: ViewModifier {
    let command: String?
    @Environment(\.commandRunner) private var runner

    func body(content: Content) -> some View {
        if let command, let runner {
            content.contextMenu {
                Button("Run") { runner.run(command) }
                Button("Run in Terminal") { runner.runInTerminal(command) }
                Button("Copy") { ShellCommand.copy(command) }
                Divider()
                Button("Save as Quick Command") { runner.save(command) }
            }
        } else {
            content
        }
    }
}

extension View {
    func commandMenu(_ command: String?) -> some View {
        modifier(CommandContextMenu(command: command))
    }
}
