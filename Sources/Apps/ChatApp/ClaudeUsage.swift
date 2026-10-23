import Foundation

/// Token usage of one Claude reply, read from a Claude Code transcript (`~/.claude/projects/*/*.jsonl`).
struct UsageRecord: Hashable, Sendable {
    let timestamp: Date
    let model: String
    let project: String
    let sessionID: String
    let input: Int
    let output: Int
    let cacheWrite: Int
    let cacheRead: Int

    /// Tokens that represent work: everything except cheap cache re-reads (which would dwarf the rest).
    var work: Int { input + output + cacheWrite }
}

/// Totals for a slice of usage.
struct UsageTotals: Equatable, Sendable {
    var input = 0
    var output = 0
    var cacheWrite = 0
    var cacheRead = 0
    var work: Int { input + output + cacheWrite }

    mutating func add(_ r: UsageRecord) {
        input += r.input
        output += r.output
        cacheWrite += r.cacheWrite
        cacheRead += r.cacheRead
    }
}

/// A row in a breakdown: a model, project or session and its work tokens.
struct UsageSlice: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let work: Int
}

/// Usage over the windows shown in the Overview, plus 7-day breakdowns.
struct UsageSummary: Equatable, Sendable {
    var lastFiveHours = UsageTotals()
    var today = UsageTotals()
    var week = UsageTotals()
    var byModel: [UsageSlice] = []
    var byProject: [UsageSlice] = []
    var bySession: [UsageSlice] = []

    static let empty = UsageSummary()

    /// `sessionName` maps a session id to a readable name (from the agent list), when known.
    init(records: [UsageRecord] = [], now: Date = .now, calendar: Calendar = .current,
         sessionName: (String) -> String? = { _ in nil }) {
        let fiveHoursAgo = now.addingTimeInterval(-5 * 3600)
        let startOfToday = calendar.startOfDay(for: now)
        let weekAgo = now.addingTimeInterval(-7 * 86400)
        var models: [String: Int] = [:], projects: [String: Int] = [:], sessions: [String: (Int, String)] = [:]
        for r in records where r.timestamp >= weekAgo && r.timestamp <= now.addingTimeInterval(60) {
            week.add(r)
            if r.timestamp >= startOfToday { today.add(r) }
            if r.timestamp >= fiveHoursAgo { lastFiveHours.add(r) }
            models[Self.modelLabel(r.model), default: 0] += r.work
            projects[r.project, default: 0] += r.work
            let current = sessions[r.sessionID] ?? (0, sessionName(r.sessionID) ?? r.project)
            sessions[r.sessionID] = (current.0 + r.work, current.1)
        }
        func top(_ d: [String: Int], _ n: Int) -> [UsageSlice] {
            d.filter { $0.value > 0 }.sorted { $0.value > $1.value }.prefix(n).map { UsageSlice(id: $0.key, label: $0.key, work: $0.value) }
        }
        byModel = top(models, 6)
        byProject = top(projects, 6)
        bySession = sessions.filter { $0.value.0 > 0 }.sorted { $0.value.0 > $1.value.0 }.prefix(6)
            .map { UsageSlice(id: $0.key, label: $0.value.1, work: $0.value.0) }
    }

    /// "claude-opus-5-5" → "Opus 5.5", "claude-haiku-4-5-20251001" → "Haiku 4.5".
    static func modelLabel(_ id: String) -> String {
        let parts = id.replacingOccurrences(of: "claude-", with: "").split(separator: "-")
        guard let family = parts.first else { return id }
        let version = parts.dropFirst().prefix { $0.count <= 2 && $0.allSatisfy(\.isNumber) }
        let name = family.prefix(1).uppercased() + family.dropFirst()
        return version.isEmpty ? name : "\(name) \(version.joined(separator: "."))"
    }

    /// 1234 → "1.2K", 3_400_000 → "3.4M".
    static func format(_ tokens: Int) -> String {
        let value = Double(tokens)
        switch value {
        case 1_000_000_000...: return String(format: "%.1fB", value / 1_000_000_000)
        case 1_000_000...: return String(format: "%.1fM", value / 1_000_000)
        case 1_000...: return String(format: "%.1fK", value / 1_000)
        default: return "\(tokens)"
        }
    }
}

/// Reads usage from Claude Code transcripts. Only the usage numbers, model, time, project and session are read —
/// never message text. Unchanged files are not re-read.
enum UsageScanner {
    static var projectsDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".claude/projects")
    }

    /// Parses transcript lines into records, skipping duplicates (a streamed reply is logged more than once with the
    /// same message and request ids).
    static func records(fromLines data: Data, seen: inout Set<String>) -> [UsageRecord] {
        var result: [UsageRecord] = []
        let needle = Data("\"usage\"".utf8)
        for line in data.split(separator: UInt8(ascii: "\n")) where line.range(of: needle) != nil {
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  entry["type"] as? String == "assistant",
                  let message = entry["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let stamp = entry["timestamp"] as? String,
                  let time = parseDate(stamp) else { continue }
            let key = "\(message["id"] as? String ?? UUID().uuidString):\(entry["requestId"] as? String ?? "")"
            guard seen.insert(key).inserted else { continue }
            let int = { (k: String) in (usage[k] as? NSNumber)?.intValue ?? 0 }
            let cwd = entry["cwd"] as? String ?? ""
            result.append(UsageRecord(
                timestamp: time,
                model: message["model"] as? String ?? "unknown",
                project: cwd.isEmpty ? "?" : URL(fileURLWithPath: cwd).lastPathComponent,
                sessionID: entry["sessionId"] as? String ?? "",
                input: int("input_tokens"),
                output: int("output_tokens"),
                cacheWrite: int("cache_creation_input_tokens"),
                cacheRead: int("cache_read_input_tokens")
            ))
        }
        return result
    }

    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let plain = ISO8601DateFormatter()

    static func parseDate(_ s: String) -> Date? {
        fractional.date(from: s) ?? plain.date(from: s)
    }

    /// Per-file cache: records keyed by path, valid while size and modification date are unchanged.
    final class Cache: @unchecked Sendable {
        struct Entry { let size: Int; let modified: Date; let records: [UsageRecord] }
        private var entries: [String: Entry] = [:]
        private let lock = NSLock()

        /// All records from transcripts modified within `days`, re-reading only changed files.
        func load(days: Int = 7, directory: URL = UsageScanner.projectsDirectory) -> [UsageRecord] {
            let cutoff = Date().addingTimeInterval(Double(-days) * 86400)
            let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
            guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else {
                return []
            }
            var all: [UsageRecord] = []
            var seen = Set<String>()
            var live = Set<String>()
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      let modified = values.contentModificationDate, modified >= cutoff else { continue }
                let size = values.fileSize ?? 0
                live.insert(url.path)
                lock.lock()
                let cached = entries[url.path]
                lock.unlock()
                let records: [UsageRecord]
                if let cached, cached.size == size, cached.modified == modified {
                    records = cached.records
                } else {
                    var fileSeen = Set<String>()
                    records = (try? Data(contentsOf: url)).map { UsageScanner.records(fromLines: $0, seen: &fileSeen) } ?? []
                    lock.lock()
                    entries[url.path] = Entry(size: size, modified: modified, records: records)
                    lock.unlock()
                }
                // De-duplicate across files too (resumed sessions can repeat earlier replies).
                for r in records {
                    let key = "\(r.sessionID):\(r.timestamp.timeIntervalSince1970):\(r.output):\(r.input)"
                    if seen.insert(key).inserted { all.append(r) }
                }
            }
            lock.lock()
            entries = entries.filter { live.contains($0.key) }
            lock.unlock()
            return all
        }
    }
}

/// Keeps a usage summary fresh while it's on screen.
@MainActor @Observable
final class ClaudeUsageMonitor {
    private(set) var summary = UsageSummary.empty
    private(set) var hasLoaded = false
    private(set) var lastUpdated: Date?

    @ObservationIgnored private let cache = UsageScanner.Cache()
    @ObservationIgnored private var refreshing = false

    /// Re-scans (off the main thread) unless it did so in the last 30 seconds.
    func refresh(force: Bool = false, sessionName: @escaping @Sendable (String) -> String? = { _ in nil }) async {
        if refreshing { return }
        if !force, let lastUpdated, Date().timeIntervalSince(lastUpdated) < 30 { return }
        refreshing = true
        defer { refreshing = false }
        let cache = self.cache
        let summary = await Task.detached(priority: .utility) {
            UsageSummary(records: cache.load(), now: .now, sessionName: sessionName)
        }.value
        self.summary = summary
        hasLoaded = true
        lastUpdated = Date()
    }
}
