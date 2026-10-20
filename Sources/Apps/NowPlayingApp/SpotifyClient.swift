import AppKit

struct Track: Equatable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let artworkURL: URL?
    /// Seconds.
    let duration: Double
}

struct PlayerSnapshot: Equatable {
    var isPlaying: Bool
    var track: Track?
    /// Seconds into the track when the snapshot was taken.
    var position: Double
}

/// Talks to Spotify over AppleScript. Scripts run in an `osascript` child process so a
/// slow Spotify or the first-run Automation consent prompt never blocks the UI.
enum SpotifyClient {
    static let bundleID = "com.spotify.client"

    enum ClientError: LocalizedError {
        case notAuthorized, script(String)

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                "Allow NotchMan to control Spotify in System Settings → Privacy & Security → Automation."
            case .script(let message):
                message
            }
        }
    }

    @MainActor static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    private static let stateScript = """
    if application "Spotify" is not running then return "notrunning"
    tell application "Spotify"
        set s to player state as string
        if s is "stopped" then return "stopped"
        set t to current track
        set out to s & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (album of t)
        set out to out & linefeed & (artwork url of t) & linefeed & ((duration of t) as string)
        return out & linefeed & ((player position) as string) & linefeed & (id of t)
    end tell
    """

    /// Returns nil when Spotify isn't running.
    static func snapshot() async throws -> PlayerSnapshot? {
        let output = try await run(stateScript)
        if output == "notrunning" { return nil }
        if output == "stopped" { return PlayerSnapshot(isPlaying: false, track: nil, position: 0) }
        let lines = output.components(separatedBy: "\n")
        guard lines.count >= 8 else { throw ClientError.script("Unexpected Spotify response") }
        let track = Track(
            id: lines[7],
            title: lines[1],
            artist: lines[2],
            album: lines[3],
            artworkURL: URL(string: lines[4]),
            duration: number(lines[5]) / 1000
        )
        return PlayerSnapshot(isPlaying: lines[0] == "playing", track: track, position: number(lines[6]))
    }

    enum Command: String {
        case playPause = "playpause"
        case next = "next track"
        case previous = "previous track"
    }

    static func send(_ command: Command) async throws {
        _ = try await run("""
        if application "Spotify" is running then tell application "Spotify" to \(command.rawValue)
        """)
    }

    static func seek(to seconds: Double) async throws {
        _ = try await run("""
        if application "Spotify" is running then tell application "Spotify" to set player position to \(Int(seconds))
        """)
    }

    /// Plays a track, optionally within a playlist/album context so next/previous stay in it.
    /// With only a context URI (e.g. a playlist), plays it from the start. Launches Spotify if needed.
    static func play(_ uri: String, context: String? = nil) async throws {
        // URIs are interpolated into AppleScript, so only allow the plain `spotify:…` form.
        guard isSafeURI(uri), context.map(isSafeURI) ?? true else { throw ClientError.script("Invalid Spotify URI") }
        let inContext = context.map { " in context \"\($0)\"" } ?? ""
        _ = try await run("tell application \"Spotify\" to play track \"\(uri)\"\(inContext)")
    }

    static func isSafeURI(_ uri: String) -> Bool {
        uri.range(of: #"^spotify:[A-Za-z0-9:]+$"#, options: .regularExpression) != nil
    }

    /// AppleScript formats reals with the user's decimal separator.
    private static func number(_ string: String) -> Double {
        Double(string.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    private static func run(_ script: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let stdout = Pipe(), stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            process.terminationHandler = { process in
                let out = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if process.terminationStatus == 0 {
                    continuation.resume(returning: out)
                } else if err.contains("-1743") {
                    continuation.resume(throwing: ClientError.notAuthorized)
                } else {
                    continuation.resume(throwing: ClientError.script(err.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
