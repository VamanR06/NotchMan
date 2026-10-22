import AppKit
import CoreServices
import NotchKit

/// A Claude Code session, as listed by `claude agents --json`.
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

    /// Called with transitions after each refresh.
    @ObservationIgnored var onEvents: (([AgentEvent]) -> Void)?

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
        return events
    }

    /// Project folders seen in current sessions, most recent first (for "New agent").
    var recentFolders: [String] {
        var seen = Set<String>()
        return agents.sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
            .map(\.cwd)
            .filter { seen.insert($0).inserted }
    }

    // MARK: - Actions

    /// Opens Terminal attached to a background agent (via a `.command` file, so no Automation permission).
    func attach(_ agent: ClaudeAgent) async {
        guard let path = await claudePath() else { return }
        let command = agent.shortID.map { "\(Shell.quote(path)) attach \(Shell.quote($0))" }
            ?? "\(Shell.quote(path)) --resume \(Shell.quote(agent.id))"
        openInTerminal(AgentScripts.commandFile(cwd: agent.cwd, command: command), name: "attach-\(agent.shortID ?? agent.id)")
    }

    /// Starts a background agent in `folder` with `prompt`. Only ever called from an explicit user action.
    func dispatch(prompt: String, in folder: String) async throws {
        guard let path = await claudePath() else { throw Shell.ShellError.failed("claude not found") }
        _ = try await Shell.run(path, ["--bg", prompt], in: folder)
        await refresh()
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

/// Calls `handler` (on the main queue) when anything under `paths` changes, coalesced over half a second.
final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private let box: Box

    // Only touched on the main queue (the stream is scheduled there).
    private final class Box: @unchecked Sendable {
        let handler: @MainActor () -> Void
        init(_ handler: @escaping @MainActor () -> Void) { self.handler = handler }
    }

    init(paths: [String], handler: @escaping @MainActor () -> Void) {
        box = Box(handler)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { box.handler() }
        }
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty,
              let stream = FSEventStreamCreate(nil, callback, &context, existing as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
