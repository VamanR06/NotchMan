import AppKit
import CoreServices
import NotchKit

/// A Claude Code session, as listed by `claude agents --json`.
/// How much a new agent may do on its own: Claude Code's `--permission-mode`.
enum AgentMode: String, CaseIterable, Identifiable {
    case plan, manual, acceptEdits, auto

    var id: String { rawValue }

    var name: String {
        switch self {
        case .plan: "Plan"
        case .manual: "Ask first"
        case .acceptEdits: "Accept edits"
        case .auto: "Auto"
        }
    }

    var detail: String {
        switch self {
        case .plan: "Reads and plans, changes nothing until you approve"
        case .manual: "Asks before every edit and command"
        case .acceptEdits: "Edits files, asks before commands"
        case .auto: "Works on its own, stops for risky actions"
        }
    }

    var systemImage: String {
        switch self {
        case .plan: "list.bullet.clipboard"
        case .manual: "hand.raised"
        case .acceptEdits: "pencil"
        case .auto: "bolt"
        }
    }
}

struct ClaudeAgent: Identifiable, Hashable {
    enum Kind: String { case background, interactive }

    /// What the user cares about at a glance.
    enum Phase: Int, Comparable {
        case needsYou, working, done, idle
        static func < (a: Phase, b: Phase) -> Bool { a.rawValue < b.rawValue }
    }

    /// The session ID (stable across refreshes).
    let id: String
    /// Short ID used by `claude attach` (background sessions only).
    let shortID: String?
    let name: String
    let cwd: String
    let kind: Kind
    /// Background sessions: working / blocked / done.
    let state: String?
    /// busy / idle.
    let status: String?
    let startedAt: Date?

    var project: String { URL(fileURLWithPath: cwd).lastPathComponent }

    var phase: Phase {
        switch state {
        case "blocked": return .needsYou
        case "working": return .working
        case "done": return .done
        default: return status == "busy" ? .working : .idle
        }
    }

    /// Matches `query` against the session name and project folder (case-insensitive); empty matches all.
    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return name.localizedCaseInsensitiveContains(query) || cwd.localizedCaseInsensitiveContains(query)
    }

    /// Needs-you first, then working, done, idle; newest first within each.
    static func sorted(_ agents: [ClaudeAgent]) -> [ClaudeAgent] {
        agents.sorted {
            if $0.phase != $1.phase { return $0.phase < $1.phase }
            return ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast)
        }
    }

    /// Decodes `claude agents --json`, skipping entries without a session ID.
    static func decodeList(_ data: Data) throws -> [ClaudeAgent] {
        struct Raw: Decodable {
            let id: String?
            let sessionId: String?
            let name: String?
            let cwd: String?
            let kind: String?
            let state: String?
            let status: String?
            let startedAt: Double?
        }
        return try JSONDecoder().decode([Raw].self, from: data).compactMap { raw in
            guard let session = raw.sessionId ?? raw.id else { return nil }
            let kind = Kind(rawValue: raw.kind ?? "") ?? (raw.state == nil ? .interactive : .background)
            // Milliseconds since 1970 (seconds tolerated).
            let started = raw.startedAt.map { Date(timeIntervalSince1970: $0 > 1e11 ? $0 / 1000 : $0) }
            return ClaudeAgent(
                id: session,
                shortID: kind == .background ? raw.id : nil,
                name: raw.name?.isEmpty == false ? raw.name! : URL(fileURLWithPath: raw.cwd ?? "").lastPathComponent,
                cwd: raw.cwd ?? NSHomeDirectory(),
                kind: kind,
                state: raw.state,
                status: raw.status,
                startedAt: started
            )
        }
    }
}

/// A folder on the Overview. NotchMan makes one per project, which collects that project's sessions (worktrees
/// count as their repo) on their own; you can make more, rename or delete any, and move sessions between them.
struct AgentFolder: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// Sessions you moved in by hand (by session ID).
    var sessions: [String] = []
    /// Project folders whose sessions land here on their own.
    var projects: [String] = []

    init(id: UUID = UUID(), name: String, sessions: [String] = [], projects: [String] = []) {
        self.id = id
        self.name = name
        self.sessions = sessions
        self.projects = projects
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        sessions = try c.decodeIfPresent([String].self, forKey: .sessions) ?? []
        projects = try c.decodeIfPresent([String].self, forKey: .projects) ?? []
    }

    /// The folder NotchMan makes for a project's sessions, named after it.
    static func forProject(_ path: String) -> AgentFolder {
        AgentFolder(name: URL(fileURLWithPath: path).lastPathComponent, projects: [path])
    }

    /// Still just what NotchMan made for a project: its name, nothing moved in by hand.
    var isAutomatic: Bool {
        projects.count == 1 && sessions.isEmpty && name == URL(fileURLWithPath: projects[0]).lastPathComponent
    }
}

/// A folder with the sessions in it, for the Overview's tree.
struct AgentProject: Identifiable, Equatable {
    let folder: AgentFolder
    /// Needs-you first, then working, done, idle; newest first within each.
    let agents: [ClaudeAgent]

    var id: String { "folder:\(folder.id)" }
    var name: String { folder.name }
    /// The project it collects sessions from, if any.
    var path: String? { folder.projects.first }
    /// A project's own folder with one session shows as just that session's row, to keep the list short.
    var showsAsRow: Bool { folder.isAutomatic && agents.count == 1 }
    /// The most urgent of its sessions'.
    var phase: ClaudeAgent.Phase { agents.map(\.phase).min() ?? .idle }
    var latest: Date { agents.compactMap(\.startedAt).max() ?? .distantPast }
    /// Open while something in it needs you or is working; finished and idle projects start folded.
    var startsExpanded: Bool { phase <= .working && !agents.isEmpty }

    /// "1 needs you · 2 working · 3 done"
    var summary: String {
        [(ClaudeAgent.Phase.needsYou, "needs you"), (.working, "working"), (.done, "done"), (.idle, "idle")]
            .compactMap { phase, label in
                let count = agents.filter { $0.phase == phase }.count
                return count > 0 ? "\(count) \(label)" : nil
            }
            .joined(separator: " · ")
    }

    /// Puts each session in the folder you moved it to, else its project's folder (a new one for a project that
    /// has none yet: see `missingProjects`). Empty folders you made show first, waiting to be filled; a project's
    /// folder with no sessions left doesn't show. Then the most urgent folder first, then the most recently started.
    static func group(_ agents: [ClaudeAgent], folders: [AgentFolder]) -> [AgentProject] {
        var folders = folders
        var members: [UUID: [ClaudeAgent]] = [:]
        for agent in agents {
            let path = ClaudeAgentsMonitor.projectFolder(agent.cwd)
            let folder = folders.first { $0.sessions.contains(agent.id) } ?? folders.first { $0.projects.contains(path) }
                ?? { let made = AgentFolder.forProject(path); folders.append(made); return made }()
            members[folder.id, default: []].append(agent)
        }
        return folders
            .map { AgentProject(folder: $0, agents: ClaudeAgent.sorted(members[$0.id] ?? [])) }
            .filter { !$0.agents.isEmpty || $0.folder.projects.isEmpty }
            .sorted {
                if $0.agents.isEmpty != $1.agents.isEmpty { return $0.agents.isEmpty }
                if $0.phase != $1.phase { return $0.phase < $1.phase }
                if $0.latest != $1.latest { return $0.latest > $1.latest }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    /// Projects with sessions that belong in no folder yet (none moved by hand, no folder for the project).
    static func missingProjects(_ agents: [ClaudeAgent], folders: [AgentFolder]) -> [String] {
        var seen = Set<String>()
        return agents.compactMap { agent in
            let path = ClaudeAgentsMonitor.projectFolder(agent.cwd)
            guard !folders.contains(where: { $0.sessions.contains(agent.id) || $0.projects.contains(path) }),
                  seen.insert(path).inserted else { return nil }
            return path
        }
    }
}

/// Something about an agent worth telling the user.
enum AgentEvent: Equatable {
    case needsYou(ClaudeAgent)
    case finished(ClaudeAgent)

    var agent: ClaudeAgent {
        switch self {
        case .needsYou(let agent), .finished(let agent): agent
        }
    }
}

enum AgentTransitions {
    /// Interactive sessions only count as "finished" if they were busy at least this long.
    static let minimumInteractiveWork: TimeInterval = 10

    /// Compares two snapshots. Agents seen for the first time never produce events (so launching NotchMan
    /// doesn't announce everything that's already blocked or done).
    static func events(from old: [String: ClaudeAgent], to new: [ClaudeAgent],
                       workingSince: [String: Date], now: Date) -> [AgentEvent] {
        new.compactMap { agent in
            guard let before = old[agent.id], before.phase != agent.phase else { return nil }
            switch (before.phase, agent.phase) {
            case (_, .needsYou):
                return .needsYou(agent)
            case (.working, .done):
                return .finished(agent)
            case (.working, .idle) where agent.kind == .interactive:
                let worked = workingSince[agent.id].map { now.timeIntervalSince($0) } ?? 0
                return worked >= minimumInteractiveWork ? .finished(agent) : nil
            default:
                return nil
            }
        }
    }
}

/// Keeps `agents` in sync with `claude agents --json`, re-running it when Claude Code's session files change.
@MainActor @Observable
final class ClaudeAgentsMonitor {
    private(set) var agents: [ClaudeAgent] = []
    private(set) var hasLoaded = false
    private(set) var error: String?
    private(set) var limits: ClaudeLimits?
    private(set) var limitsError: String?
    @ObservationIgnored private var limitsFetchedAt: Date?
    @ObservationIgnored private var limitsRunning = false

    /// Called with transitions after each refresh.
    @ObservationIgnored var onEvents: (([AgentEvent]) -> Void)?
    /// Called after every snapshot.
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private var fallback: Task<Void, Never>?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var queued = false
    @ObservationIgnored private var lastRun = Date.distantPast
    @ObservationIgnored private var workingSince: [String: Date] = [:]

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Explicit path to `claude` from settings; empty means auto-detect.
    var claudePathOverride: String {
        get { defaults.string(forKey: "claudePath") ?? "" }
        set { defaults.set(newValue, forKey: "claudePath"); resolvedPath = nil }
    }

    @ObservationIgnored private var resolvedPath: String?

    /// GUI apps don't inherit the shell's PATH, so look in the usual install locations first.
    func claudePath() async -> String? {
        if let resolvedPath { return resolvedPath }
        let override = claudePathOverride.trimmingCharacters(in: .whitespaces)
        let home = NSHomeDirectory()
        let candidates = (override.isEmpty ? [] : [override]) + [
            "\(home)/.local/bin/claude", "/usr/local/bin/claude", "/opt/homebrew/bin/claude", "\(home)/.claude/local/claude",
        ]
        if let found = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) {
            resolvedPath = found
            return found
        }
        let fromShell = try? await Shell.run("/bin/zsh", ["-lc", "command -v claude"]).trimmingCharacters(in: .whitespacesAndNewlines)
        if let fromShell, !fromShell.isEmpty, FileManager.default.isExecutableFile(atPath: fromShell) {
            resolvedPath = fromShell
        }
        return resolvedPath
    }

    func start() {
        let base = NSHomeDirectory() + "/.claude"
        watcher = DirectoryWatcher(paths: ["\(base)/sessions", "\(base)/jobs"]) { [weak self] in
            self?.refreshSoon()
        }
        fallback = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func stop() {
        watcher = nil
        fallback?.cancel()
    }

    private func refreshSoon() {
        Task { await refresh() }
    }

    /// Runs `claude agents --json`, at most once a second; changes arriving mid-run trigger one more run.
    func refresh() async {
        guard !running else { queued = true; return }
        running = true
        defer {
            running = false
            if queued {
                queued = false
                Task { await refresh() }
            }
        }
        let wait = 1 - Date().timeIntervalSince(lastRun)
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        lastRun = Date()

        guard let path = await claudePath() else {
            error = "Couldn't find the claude command. Set its path in Settings → Agents."
            return
        }
        do {
            // --all keeps finished background sessions listed after their process ends (attaching revives them).
            let output = try await Shell.run(path, ["agents", "--json", "--all"])
            let events = apply(try ClaudeAgent.decodeList(Data(output.utf8)), now: Date())
            error = nil
            if !events.isEmpty { onEvents?(events) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Takes a fresh snapshot and returns what changed (nothing on the first snapshot).
    @discardableResult
    func apply(_ fresh: [ClaudeAgent], now: Date) -> [AgentEvent] {
        let previous = Dictionary(agents.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let events = hasLoaded ? AgentTransitions.events(from: previous, to: fresh, workingSince: workingSince, now: now) : []
        for agent in fresh {
            if agent.phase == .working { workingSince[agent.id] = workingSince[agent.id] ?? now } else { workingSince[agent.id] = nil }
        }
        agents = ClaudeAgent.sorted(fresh)
        hasLoaded = true
        onChange?()
        return events
    }

    /// Runs `claude -p "/usage"` (a free local command; piped stdout also skips the folder-trust prompt) and
    /// parses it. Cached for 2 minutes unless `force`.
    func refreshLimits(force: Bool = false) async {
        guard !limitsRunning else { return }
        if !force, let limitsFetchedAt, Date().timeIntervalSince(limitsFetchedAt) < 120 { return }
        limitsRunning = true
        defer { limitsRunning = false }
        guard let path = await claudePath() else {
            limitsError = "Couldn't find the claude command."
            return
        }
        do {
            let output = try await Shell.run(path, ["-p", "/usage"], timeout: 30)
            limits = ClaudeLimits.parse(output)
            limitsError = nil
        } catch {
            limitsError = error.localizedDescription
        }
        limitsFetchedAt = Date()
    }

    /// Project folders seen in current sessions, most recent first (for "New agent"). A session in a worktree
    /// counts as its repo's.
    var recentFolders: [String] {
        var seen = Set<String>()
        return agents.sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
            .map { Self.projectFolder($0.cwd) }
            .filter { seen.insert($0).inserted }
    }

    /// The repo a Claude Code worktree (`<repo>/.claude/worktrees/<name>`) belongs to; other folders as they are.
    nonisolated static func projectFolder(_ path: String) -> String {
        guard let range = path.range(of: "/.claude/worktrees/") else { return path }
        return String(path[..<range.lowerBound])
    }

    /// The mode New Agent starts in; the last one picked.
    var newAgentMode: AgentMode {
        get { defaults.string(forKey: "newAgentMode").flatMap(AgentMode.init(rawValue:)) ?? .plan }
        set { defaults.set(newValue.rawValue, forKey: "newAgentMode") }
    }

    // MARK: - Actions

    /// Opens Terminal attached to a background agent (via a `.command` file, so no Automation permission).
    func attach(_ agent: ClaudeAgent) async {
        guard let path = await claudePath() else { return }
        let command = agent.shortID.map { "\(Shell.quote(path)) attach \(Shell.quote($0))" }
            ?? "\(Shell.quote(path)) --resume \(Shell.quote(agent.id))"
        openInTerminal(AgentScripts.commandFile(cwd: agent.cwd, command: command), name: "attach-\(agent.shortID ?? agent.id)")
    }

    /// Stops a background session; its conversation is kept (attaching reopens it).
    func stop(_ agent: ClaudeAgent) async throws {
        try await runOnSession("stop", agent)
    }

    /// Deletes a background session and its conversation (and its worktree when Claude Code deems that safe).
    /// Never passes the discard/force flags: if a worktree has unpushed work, `claude rm` refuses and its
    /// message is thrown so the user sees it.
    func delete(_ agent: ClaudeAgent) async throws {
        try await runOnSession("rm", agent)
    }

    private func runOnSession(_ command: String, _ agent: ClaudeAgent) async throws {
        guard let shortID = agent.shortID else { throw Shell.ShellError.failed("Only background sessions can be \(command == "rm" ? "deleted" : "stopped").") }
        guard let path = await claudePath() else { throw Shell.ShellError.failed("claude not found") }
        defer { Task { await refresh() } }
        _ = try await Shell.run(path, [command, shortID])
    }

    /// Starts a background agent in `folder` with `prompt`, in `mode`. Only ever called from an explicit user action.
    func dispatch(prompt: String, in folder: String, mode: AgentMode) async throws {
        guard let path = await claudePath() else { throw Shell.ShellError.failed("claude not found") }
        _ = try await Shell.run(path, Self.dispatchArguments(prompt: prompt, mode: mode), in: folder)
        await refresh()
    }

    static func dispatchArguments(prompt: String, mode: AgentMode) -> [String] {
        ["--bg", "--permission-mode", mode.rawValue, prompt]
    }

    private func openInTerminal(_ script: String, name: String) {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "NotchMan")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "\(name).command")
        do {
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            NSWorkspace.shared.open(file)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

enum AgentScripts {
    /// A Terminal `.command` script that runs `command` in `cwd`.
    static func commandFile(cwd: String, command: String) -> String {
        "#!/bin/zsh -l\ncd \(Shell.quote(cwd)) || exit 1\nexec \(command)\n"
    }
}

/// Opening a session's folder in an editor.
enum AgentEditor: String, CaseIterable, Identifiable {
    case vscode, cursor

    var id: String { rawValue }
    var name: String { self == .vscode ? "VS Code" : "Cursor" }
    var bundleID: String { self == .vscode ? "com.microsoft.VSCode" : "com.todesktop.230313mzl4w4u92" }

    @MainActor func open(_ folder: String) {
        let url = URL(fileURLWithPath: folder)
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Runs command-line tools off the main thread.
enum Shell {
    enum ShellError: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            switch self { case .failed(let message): message }
        }
    }

    /// Single-quotes `s` for zsh/sh.
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func run(_ executable: String, _ arguments: [String], in directory: String? = nil,
                    timeout: TimeInterval = 15) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
            let stdout = Pipe(), stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            process.standardInput = FileHandle.nullDevice
            let output = OutputBuffer()
            // Read continuously so large outputs can't fill the pipe and stall the process.
            stdout.fileHandleForReading.readabilityHandler = { output.append($0.availableData) }
            process.terminationHandler = { process in
                stdout.fileHandleForReading.readabilityHandler = nil
                output.append(stdout.fileHandleForReading.readDataToEndOfFile())
                let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if process.terminationStatus == 0 {
                    continuation.resume(returning: output.string)
                } else {
                    let message = err.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: ShellError.failed(message.isEmpty ? "exit \(process.terminationStatus)" : message))
                }
            }
            do {
                try process.run()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning { process.terminate() }
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private final class OutputBuffer: @unchecked Sendable {
        private var data = Data()
        private let lock = NSLock()
        func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
        var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    }
}
