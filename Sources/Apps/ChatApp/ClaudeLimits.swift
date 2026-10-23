import Foundation

/// One of Claude Code's plan limit windows ("Current session", "Current week (all models)", …).
struct ClaudeLimitWindow: Identifiable, Equatable, Sendable {
    let label: String
    let percent: Int
    let resetsText: String
    var id: String { label }
}

/// A "Last 24h" / "Last 7d" usage-characteristics block (not a limit — context on what's driving it).
struct ClaudeUsagePeriod: Identifiable, Equatable, Sendable {
    let label: String
    let requests: Int?
    let sessions: Int?
    var notes: [String] = []
    var id: String { label }
}

/// `claude -p "/usage"`'s plain-text report, parsed. `/usage` is a local, no-cost command — this never spends
/// a model turn, and running non-interactively (piped stdout) also skips the folder-trust prompt.
struct ClaudeLimits: Equatable, Sendable {
    var windows: [ClaudeLimitWindow] = []
    var periods: [ClaudeUsagePeriod] = []
    /// e.g. "You are currently using your subscription to power your Claude Code usage."
    var planNote: String?
    var raw: String = ""

    static let empty = ClaudeLimits()

    static func parse(_ text: String) -> ClaudeLimits {
        var result = ClaudeLimits(raw: text)
        var currentPeriod: Int?
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let lower = line.lowercased()
            if lower.contains("what's contributing") || lower.hasPrefix("approximate") { continue }

            if let window = parseWindow(line) {
                result.windows.append(window)
                continue
            }
            if let period = parsePeriodHeader(line) {
                result.periods.append(period)
                currentPeriod = result.periods.count - 1
                continue
            }
            if let index = currentPeriod {
                result.periods[index].notes.append(line)
            } else if result.planNote == nil && result.windows.isEmpty {
                result.planNote = line
            }
        }
        return result
    }

    /// "Current week (all models): 81% used · resets Oct 23 at 5:59pm (America/Detroit)"
    private static func parseWindow(_ line: String) -> ClaudeLimitWindow? {
        guard let colon = line.range(of: ": ") else { return nil }
        let label = String(line[line.startIndex..<colon.lowerBound])
        let rest = line[colon.upperBound...]
        guard let percentMark = rest.range(of: "% used"),
              let percent = Int(rest[rest.startIndex..<percentMark.lowerBound].trimmingCharacters(in: .whitespaces)),
              let resetsMark = rest.range(of: "resets ") else { return nil }
        let resetsText = String(rest[resetsMark.upperBound...]).trimmingCharacters(in: .whitespaces)
        return ClaudeLimitWindow(label: label, percent: percent, resetsText: resetsText)
    }

    /// "Last 24h · 331 requests · 5 sessions"
    private static func parsePeriodHeader(_ line: String) -> ClaudeUsagePeriod? {
        guard line.hasPrefix("Last ") else { return nil }
        let parts = line.split(separator: "·").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let label = parts.first, label.hasPrefix("Last ") else { return nil }
        var requests: Int?, sessions: Int?
        for part in parts.dropFirst() {
            let words = part.split(separator: " ")
            guard let count = words.first.flatMap({ Int($0) }) else { continue }
            if part.hasSuffix("requests") { requests = count }
            if part.hasSuffix("sessions") { sessions = count }
        }
        return ClaudeUsagePeriod(label: label, requests: requests, sessions: sessions)
    }
}

extension ClaudeLimitWindow {
    /// white (plenty left) → orange (getting close) → red (almost out).
    var isNearLimit: Bool { percent >= 75 }
    var isAtLimit: Bool { percent >= 90 }
}
