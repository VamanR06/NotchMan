import Foundation

/// What a quick-add line like "Call recruiter fri 3pm for 30m" means: the title left once the date words are
/// taken out, the date, whether it named a time, and an optional length.
public struct QuickAdd: Equatable, Sendable {
    public var title: String
    public var date: Date?
    /// A time of day was given ("3pm", "noon", "in 2h"); otherwise `date` is the start of a day.
    public var hasTime: Bool
    public var duration: TimeInterval?

    public init(title: String, date: Date?, hasTime: Bool, duration: TimeInterval?) {
        self.title = title
        self.date = date
        self.hasTime = hasTime
        self.duration = duration
    }

    /// Something at a time reads as an event; a bare day or no date as a task. The user can still switch.
    public var looksLikeEvent: Bool { date != nil && hasTime }
}

/// Parses quick-add text with plain rules and `NSDataDetector` — exact, predictable, and testable; nothing
/// leaves the Mac. The UI shows a preview of the result, so an odd parse is seen before anything is created.
public enum QuickAddParser {
    public static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> QuickAdd {
        var working = normalize(text)

        // "for 45m" / "for 1.5 hours": a length, not a date.
        var duration: TimeInterval?
        if let match = firstMatch(#"\bfor\s+(\d+(?:\.\d+)?)\s*(hours?|hrs?|h|minutes?|mins?|m)\b"#, in: working),
           let amount = Double(working[match.range(at: 1)]) {
            let unit = working[match.range(at: 2)].lowercased()
            duration = amount * (unit.hasPrefix("h") ? 3600 : 60)
            working = remove(match.range, from: working)
        }

        var date: Date?
        var hasTime = false
        if let match = firstMatch(#"\bin\s+(\d+)\s*(hours?|hrs?|h|minutes?|mins?|m)\b"#, in: working),
           let amount = Double(working[match.range(at: 1)]) {
            // "in 2h" / "in 20 minutes": from now.
            let unit = working[match.range(at: 2)].lowercased()
            date = now.addingTimeInterval(amount * (unit.hasPrefix("h") ? 3600 : 60))
            hasTime = true
            working = remove(match.range, from: working)
        } else if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
           let match = detector.firstMatch(in: working, range: NSRange(working.startIndex..., in: working)),
           let found = match.date {
            let phrase = working[match.range].lowercased()
            hasTime = firstMatch(#"\d\s*(am|pm|a\.m\.|p\.m\.)|\d:\d\d|\bnoon\b|\bmidnight\b|\bin \d+ (hours?|minutes?)\b"#,
                                 in: phrase) != nil
            if hasTime {
                // A bare time already past today ("9am" at 3pm) means tomorrow.
                var start = found
                if start < now, calendar.isDate(start, inSameDayAs: now), !phrase.contains("today") {
                    start = calendar.date(byAdding: .day, value: 1, to: start) ?? start
                }
                date = start
            } else {
                date = calendar.startOfDay(for: found)
            }
            working = remove(match.range, from: working, droppingLeading: ["at", "on", "by", "due", "@"])
        }

        let title = working
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",;-–—")))
        return QuickAdd(title: title, date: date, hasTime: hasTime, duration: duration)
    }

    /// Shorthands the date detector doesn't know.
    static func normalize(_ text: String) -> String {
        var result = text
        let replacements: [(String, String)] = [
            (#"\b(tmrw|tmr|tmw|tomo)\b"#, "tomorrow"),
            (#"\b(eod)\b"#, "today 5pm"),
        ]
        for (pattern, template) in replacements {
            result = result.replacingOccurrences(of: pattern, with: template, options: [.regularExpression, .caseInsensitive])
        }
        return result
    }

    private static func firstMatch(_ pattern: String, in text: String) -> NSTextCheckingResult? {
        let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        return regex?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    /// Removes `range`, and a dangling connective word just before it ("call mom *at* 3pm" → "call mom").
    private static func remove(_ range: NSRange, from text: String, droppingLeading words: [String] = []) -> String {
        guard let swiftRange = Range(range, in: text) else { return text }
        var before = String(text[..<swiftRange.lowerBound])
        let after = String(text[swiftRange.upperBound...])
        let trimmed = before.trimmingCharacters(in: .whitespaces)
        if let last = trimmed.split(separator: " ").last, words.contains(last.lowercased()) {
            before = String(trimmed.dropLast(last.count))
        }
        return before + " " + after
    }
}

private extension String {
    subscript(range: NSRange) -> Substring {
        Range(range, in: self).map { self[$0] } ?? ""
    }
}
