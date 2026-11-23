import Foundation
import NotchKit

/// Makes (or changes) a notch app with Claude Code: asks for the manifest and script, loads them in a scratch runtime
/// to check they work, sends any error back for Claude to fix (twice at most), then writes the app's folder.
public struct ModGenerator: Sendable {
    /// Runs `claude` with arguments and returns its stdout (replaced in tests).
    public var claude: @Sendable ([String]) async throws -> String
    public static let maxRepairs = 2

    public init(claude: @escaping @Sendable ([String]) async throws -> String = ModGenerator.runClaude) {
        self.claude = claude
    }

    public enum Failure: LocalizedError {
        case noReply(String)
        case stillBroken(String)

        public var errorDescription: String? {
            switch self {
            case .noReply(let detail): "Claude didn't reply with an app: \(detail)"
            case .stillBroken(let detail): "Claude's app still doesn't work after fixing: \(detail)"
            }
        }
    }

    /// Writes a new app for `request` into `library` and returns its folder.
    public func make(_ request: String, in library: URL) async throws -> URL {
        let (manifest, script) = try await generate(prompt: ModAuthoring.newAppPrompt(request))
        let folder = Self.freeFolder(for: manifest.name, in: library)
        try Self.write(manifest: manifest, script: script, to: folder)
        return folder
    }

    /// Rewrites the app in `folder` with `request` applied.
    public func change(_ folder: URL, _ request: String) async throws {
        let manifestText = (try? String(contentsOf: folder.appending(path: "manifest.json"), encoding: .utf8)) ?? "{}"
        let scriptText = (try? String(contentsOf: folder.appending(path: "app.js"), encoding: .utf8)) ?? ""
        let (manifest, script) = try await generate(prompt: ModAuthoring.changePrompt(request, manifest: manifestText,
                                                                                     script: scriptText))
        try Self.write(manifest: manifest, script: script, to: folder)
    }

    private func generate(prompt: String) async throws -> (ModManifest, String) {
        var output = try await claude(Self.arguments(prompt: prompt, resume: nil))
        for attempt in 0...Self.maxRepairs {
            let reply = Self.reply(from: output)
            let problem: String
            if let (manifestText, script) = ModAuthoring.blocks(in: reply.text) {
                do {
                    let manifest = try ModManifest.decode(Data(manifestText.utf8))
                    if let error = await ModValidator.check(manifest: manifest, script: script) {
                        problem = error
                    } else {
                        return (manifest, script)
                    }
                } catch {
                    problem = error.localizedDescription
                }
            } else {
                problem = "the reply didn't have a ```json block and a ```javascript block"
                if reply.text.isEmpty { throw Failure.noReply(String(output.prefix(300))) }
            }
            guard attempt < Self.maxRepairs, let session = reply.session else { throw Failure.stillBroken(problem) }
            output = try await claude(Self.arguments(prompt: ModAuthoring.repairPrompt(problem), resume: session))
        }
        throw Failure.stillBroken("no working app")
    }

    /// `claude -p` writing text only (no tools), as JSON so the session can be resumed for a fix.
    static func arguments(prompt: String, resume session: String?) -> [String] {
        var args = ["-p", prompt, "--output-format", "json", "--max-turns", "2",
                    "--disallowedTools", "Bash,Edit,Write,NotebookEdit,Read,Glob,Grep,WebFetch,WebSearch,Agent"]
        if let session { args += ["--resume", session] }
        return args
    }

    /// The text and session id from `--output-format json` output (or the raw text if it isn't JSON).
    static func reply(from output: String) -> (text: String, session: String?) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any] else {
            return (output, nil)
        }
        return (object["result"] as? String ?? "", object["session_id"] as? String)
    }

    static func write(manifest: ModManifest, script: String, to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // Script first: the library loads an app once its manifest appears.
        try script.write(to: folder.appending(path: "app.js"), atomically: true, encoding: .utf8)
        try encoder.encode(manifest).write(to: folder.appending(path: "manifest.json"), options: .atomic)
    }

    /// `pomodoro`, or `pomodoro-2` if that's taken.
    static func freeFolder(for name: String, in library: URL) -> URL {
        let slug = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce(into: "") { result, c in
            if c != "-" || result.last != "-" { result.append(c) }
        }.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let base = slug.isEmpty ? "app" : String(slug.prefix(40))
        var candidate = library.appending(path: base)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = library.appending(path: "\(base)-\(number)")
            number += 1
        }
        return candidate
    }

    // MARK: Running claude

    public static let runClaude: @Sendable ([String]) async throws -> String = { arguments in
        guard let path = await findClaude() else {
            throw Failure.noReply("Claude Code (claude) wasn't found. Install it from claude.com/claude-code.")
        }
        return try await ModProcess.run(path, arguments, in: NSHomeDirectory(), timeout: 240)
    }

    /// Where `claude` is: the usual install places, else what a login shell finds.
    public static func findClaude() async -> String? {
        let home = NSHomeDirectory()
        let candidates = [home + "/.local/bin/claude", home + "/.claude/local/claude", "/opt/homebrew/bin/claude",
                          "/usr/local/bin/claude"]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return found }
        let path = try? await ModProcess.run("/bin/zsh", ["-l", "-c", "command -v claude"], in: nil, timeout: 10)
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.hasPrefix("/") ? trimmed : nil
    }
}

/// Loads an app in a scratch runtime (nothing saved, nothing shown) and reports the first problem, if any.
public enum ModValidator {
    @MainActor
    public static func check(manifest: ModManifest, script: String, timeout: Duration = .seconds(3)) async -> String? {
        let runtime = ModRuntime(manifest: manifest, storeURL: nil)
        var result: Result<ModNode, ModError>?
        var errors: [String] = []
        runtime.onTree = { if result == nil { result = $0 } }
        runtime.onError = { errors.append($0) }
        runtime.start(script: script)
        let deadline = ContinuousClock.now + timeout
        while result == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        runtime.stop()
        switch result {
        case .failure(let error)?: return error.localizedDescription
        case .success?: return errors.first.map { "a hook threw: \($0)" }
        case nil: return ModError.timeout("starting").localizedDescription
        }
    }
}

/// Runs a program and returns its stdout; throws with stderr when it fails or times out.
enum ModProcess {
    static func run(_ executable: String, _ arguments: [String], in directory: String?, timeout: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
            let output = Pipe(), errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            process.standardInput = FileHandle.nullDevice
            let collected = Collected()
            output.fileHandleForReading.readabilityHandler = { collected.append($0.availableData) }
            process.terminationHandler = { process in
                output.fileHandleForReading.readabilityHandler = nil
                collected.append(output.fileHandleForReading.readDataToEndOfFile())
                let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if process.terminationStatus == 0 {
                    continuation.resume(returning: collected.text)
                } else {
                    let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: ModGenerator.Failure.noReply(message.isEmpty ? "exit \(process.terminationStatus)" : message))
                }
            }
            do {
                try process.run()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if process.isRunning { process.terminate() } }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private final class Collected: @unchecked Sendable {
        private var data = Data()
        private let lock = NSLock()

        func append(_ chunk: Data) {
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }
    }
}
