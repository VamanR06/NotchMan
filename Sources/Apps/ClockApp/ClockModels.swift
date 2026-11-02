import Foundation

/// A countdown. Running, it counts down to `endsAt`; paused, it holds `pausedRemaining`. All times come from the
/// caller's `now`, so it survives relaunch (it's stored as dates, not ticks) and is easy to test.
struct CountdownTimer: Codable, Identifiable, Equatable {
    let id: UUID
    var label: String
    /// Total length, for the progress ring and Restart (grows with "+1 min").
    var duration: TimeInterval
    /// Set while running.
    var endsAt: Date?
    /// Time left while paused.
    var pausedRemaining: TimeInterval
    /// It reached zero and has rung.
    var hasRung = false

    init(id: UUID = UUID(), label: String = "", duration: TimeInterval, startingAt now: Date) {
        self.id = id
        self.label = label
        self.duration = duration
        self.endsAt = now + duration
        self.pausedRemaining = duration
    }

    var isRunning: Bool { endsAt != nil && !hasRung }

    func remaining(at now: Date) -> TimeInterval {
        guard let endsAt else { return pausedRemaining }
        return max(0, endsAt.timeIntervalSince(now))
    }

    /// Running and at zero, but hasn't rung yet.
    func isDue(at now: Date) -> Bool {
        guard let endsAt, !hasRung else { return false }
        return endsAt <= now
    }

    /// 0 at the start, 1 when done.
    func progress(at now: Date) -> Double {
        guard duration > 0 else { return 1 }
        return min(max(1 - remaining(at: now) / duration, 0), 1)
    }

    mutating func pause(at now: Date) {
        guard isRunning else { return }
        pausedRemaining = remaining(at: now)
        endsAt = nil
    }

    mutating func resume(at now: Date) {
        guard endsAt == nil, !hasRung else { return }
        endsAt = now + pausedRemaining
    }

    /// Starts over from the full duration.
    mutating func restart(at now: Date) {
        hasRung = false
        pausedRemaining = duration
        endsAt = now + duration
    }

    /// Adds time; a timer that already rang starts again with just that much.
    mutating func add(_ seconds: TimeInterval, at now: Date) {
        if hasRung {
            hasRung = false
            duration = seconds
            endsAt = now + seconds
        } else if let endsAt {
            duration += seconds
            self.endsAt = endsAt + seconds
        } else {
            duration += seconds
            pausedRemaining += seconds
        }
    }
}

/// Start/stop/lap. `accumulated` holds time from earlier runs; `startedAt` is set while running.
struct Stopwatch: Codable, Equatable {
    var accumulated: TimeInterval = 0
    var startedAt: Date?
    /// Each lap's own length, oldest first.
    var laps: [TimeInterval] = []

    var isRunning: Bool { startedAt != nil }
    var isReset: Bool { !isRunning && accumulated == 0 && laps.isEmpty }

    func elapsed(at now: Date) -> TimeInterval {
        accumulated + (startedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }

    /// The lap in progress.
    func currentLap(at now: Date) -> TimeInterval {
        max(0, elapsed(at: now) - laps.reduce(0, +))
    }

    mutating func start(at now: Date) {
        guard startedAt == nil else { return }
        startedAt = now
    }

    mutating func stop(at now: Date) {
        guard startedAt != nil else { return }
        accumulated = elapsed(at: now)
        startedAt = nil
    }

    mutating func toggle(at now: Date) {
        if isRunning { stop(at: now) } else { start(at: now) }
    }

    mutating func lap(at now: Date) {
        guard isRunning else { return }
        laps.append(currentLap(at: now))
    }

    mutating func reset() {
        self = Stopwatch()
    }

    /// Indices of the fastest and slowest laps, once there are two to compare.
    var bestAndWorstLap: (best: Int, worst: Int)? {
        guard laps.count >= 2,
              let best = laps.indices.min(by: { laps[$0] < laps[$1] }),
              let worst = laps.indices.max(by: { laps[$0] < laps[$1] }) else { return nil }
        return (best, worst)
    }
}

/// Reads what someone types to start a timer: "5" (minutes), "90s", "1h30m", "2.5 min", "1:30" (m:ss),
/// "1:00:00" (h:mm:ss). Words left over become the label: "10m tea" → 10 minutes, "tea".
enum TimerInput {
    static func parse(_ text: String) -> (duration: TimeInterval, label: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        if let match = trimmed.prefixMatch(of: #/(\d+):(\d{1,2})(?::(\d{1,2}))?/#) {
            let parts = [match.1, match.2, match.3].compactMap { $0.flatMap { Double($0) } }
            let seconds = parts.count == 3
                ? parts[0] * 3600 + parts[1] * 60 + parts[2]
                : parts[0] * 60 + parts[1]
            return valid(seconds, label: trimmed[match.range.upperBound...])
        }

        let unit = #/(\d+(?:\.\d+)?)\s*(hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s)(?![a-z])/#.ignoresCase()
        let matches = trimmed.matches(of: unit)
        if !matches.isEmpty {
            var seconds: TimeInterval = 0
            var label = trimmed
            for match in matches {
                let value = Double(match.1) ?? 0
                switch match.2.lowercased().first {
                case "h": seconds += value * 3600
                case "m": seconds += value * 60
                default: seconds += value
                }
            }
            for match in matches.reversed() { label.removeSubrange(match.range) }
            return valid(seconds, label: Substring(label))
        }

        if let match = trimmed.prefixMatch(of: #/\d+(?:\.\d+)?/#), let minutes = Double(match.output) {
            return valid(minutes * 60, label: trimmed[match.range.upperBound...])
        }
        return nil
    }

    private static func valid(_ seconds: TimeInterval, label: Substring) -> (TimeInterval, String)? {
        guard seconds >= 1 else { return nil }
        let words = label.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return (seconds.rounded(), words)
    }
}

enum ClockFormat {
    /// "4:05", "1:02:09" — for countdowns (rounded up, so a timer shows 0:00 only when it's done).
    static func countdown(_ seconds: TimeInterval) -> String {
        hms(Int(seconds.rounded(.up)))
    }

    /// "4:05.27", "1:02:09.50" — for the stopwatch.
    static func stopwatch(_ seconds: TimeInterval) -> String {
        // Whole hundredths, nudged so 65.27 (stored as 65.2699…) doesn't show as 65.26.
        let total = Int(seconds * 100 + 1e-6)
        return hms(total / 100) + String(format: ".%02d", total % 100)
    }

    /// "5 min", "1 h 30 min", "45 sec" — a timer's length as a default label.
    static func spoken(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = total % 3600 / 60, s = total % 60
        var parts: [String] = []
        if h > 0 { parts.append("\(h) h") }
        if m > 0 { parts.append("\(m) min") }
        if s > 0 || parts.isEmpty { parts.append("\(s) sec") }
        return parts.joined(separator: " ")
    }

    private static func hms(_ total: Int) -> String {
        let h = total / 3600, m = total % 3600 / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// How far a zone is from here: "+5h", "−3h 30m", "Same time".
    static func offset(of zone: TimeZone, from local: TimeZone = .current, at now: Date) -> String {
        let diff = zone.secondsFromGMT(for: now) - local.secondsFromGMT(for: now)
        guard diff != 0 else { return "Same time" }
        let sign = diff > 0 ? "+" : "−"
        let h = abs(diff) / 3600, m = abs(diff) % 3600 / 60
        return m == 0 ? "\(sign)\(h)h" : "\(sign)\(h)h \(m)m"
    }

    /// "Today", "Tomorrow" or "Yesterday" for what day it is in `zone` compared to here.
    static func relativeDay(in zone: TimeZone, from local: TimeZone = .current, at now: Date) -> String {
        func day(_ tz: TimeZone) -> Int {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = tz
            let c = calendar.dateComponents([.year, .month, .day], from: now)
            return (c.year ?? 0) * 10_000 + (c.month ?? 0) * 100 + (c.day ?? 0)
        }
        let there = day(zone), here = day(local)
        return there == here ? "Today" : there > here ? "Tomorrow" : "Yesterday"
    }

    /// "Tokyo" from "Asia/Tokyo", "New York" from "America/New_York".
    static func city(_ identifier: String) -> String {
        (identifier.split(separator: "/").last.map(String.init) ?? identifier).replacingOccurrences(of: "_", with: " ")
    }
}
