import Foundation

/// The steps of a plan Claude wrote (ExitPlanMode's Markdown), as short titles for the plan strip.
///
/// Plans are free-form, so this looks for the section that reads like the to-do list: one headed like an order of
/// work ("Build order", "Steps", "Phases"), then one headed like the work itself ("Changes", "Implementation"). It
/// takes that section's top-level list items, or its subheadings when it has no list. Without such a section, the
/// plan's own headings (less Context, Verification and the like) are the steps.
enum PlanSteps {
    private struct Heading {
        let line: Int
        let level: Int
        let text: String
    }

    static func steps(_ plan: String, limit: Int = 12) -> [String] {
        let lines = plan.components(separatedBy: "\n")
        let headings = Self.headings(lines)
        /// A heading's section: up to the next heading at its level or above (so it includes its subsections).
        func end(of heading: Heading) -> Int {
            headings.first { $0.line > heading.line && $0.level <= heading.level }?.line ?? lines.count
        }
        /// A heading's own text, before any subheading (a subsection's lists are that subsection's).
        func ownLines(of heading: Heading) -> [String] {
            let next = headings.first { $0.line > heading.line }?.line ?? lines.count
            return Array(lines[(heading.line + 1)..<next])
        }
        func subheadings(of heading: Heading) -> [Heading] {
            let inside = headings.filter { $0.line > heading.line && $0.line < end(of: heading) }
            guard let level = inside.map(\.level).min() else { return [] }
            return inside.filter { $0.level == level }
        }
        // The title (`# Plan: …`) isn't a step; neither are the sections that describe rather than list the work.
        let candidates = headings.filter { $0.level >= 2 && !isAside($0.text) }

        // A numbered list under such a heading is the surest sign of the steps; then any list, or subheadings.
        for numbered in [true, false] {
            for words in [orderWords, workWords] {
                for heading in candidates where matches(heading.text, words) {
                    let items = listItems(ownLines(of: heading), orderedOnly: numbered)
                    if items.count >= 2 { return Array(items.prefix(limit)) }
                    guard !numbered else { continue }
                    let subs = subheadings(of: heading).filter { !isAside($0.text) }
                    if subs.count >= 2 { return Array(subs.map { title($0.text) }.prefix(limit)) }
                }
            }
        }
        if let level = candidates.map(\.level).min() {
            let top = candidates.filter { $0.level == level }
            if top.count >= 2 { return Array(top.map { title($0.text) }.prefix(limit)) }
        }
        for heading in candidates {
            let items = listItems(ownLines(of: heading), orderedOnly: true)
            if items.count >= 2 { return Array(items.prefix(limit)) }
        }
        return []
    }

    private static let orderWords = #"\b(steps?|order|phases?|milestones?|sequence)\b"#
    private static let workWords = #"\b(implement\w*|changes?|tasks?|to-?dos?|build|work|approach|plan|fix(es)?)\b"#
    private static let asideWords = #"\b(context|verif\w*|files?|risks?|notes?|decisions?|setup|rules?|questions?|background|overview|summary|goals?|why|layout|mechanics?|scope|not included|assumptions?|references?)\b"#

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Sections that describe the plan rather than list its work.
    static func isAside(_ heading: String) -> Bool { matches(heading, asideWords) }

    private static func headings(_ lines: [String]) -> [Heading] {
        var headings: [Heading] = []
        var inFence = false
        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { inFence.toggle(); continue }
            guard !inFence, let match = line.firstMatch(of: /^(#{1,6})\s+(.+)$/) else { continue }
            headings.append(Heading(line: index, level: match.output.1.count,
                                    text: String(match.output.2).trimmingCharacters(in: .whitespaces)))
        }
        return headings
    }

    /// The list items at the list's outermost indent (`1.`, `-`, `*`, `- [ ]`), as titles.
    private static func listItems(_ body: [String], orderedOnly: Bool = false) -> [String] {
        var items: [(indent: Int, text: String)] = []
        var inFence = false
        for line in body {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inFence.toggle(); continue }
            if inFence { continue }
            let indent = line.prefix { $0 == " " || $0 == "\t" }.count
            if let match = trimmed.firstMatch(of: /^\d+[.)]\s+(.+)$/) {
                items.append((indent, String(match.output.1)))
            } else if !orderedOnly, let match = trimmed.firstMatch(of: /^[-*+]\s+(?:\[[ xX]\]\s+)?(.+)$/) {
                items.append((indent, String(match.output.1)))
            }
        }
        guard let outer = items.map(\.indent).min() else { return [] }
        return items.filter { $0.indent == outer }.map { title($0.text) }.filter { !$0.isEmpty }
    }

    /// A step's short title: a bold lead-in on its own ("**E2E slice:** register → …" → "E2E slice"), else its first
    /// sentence, without Markdown marks, cut to fit one line.
    static func title(_ text: String) -> String {
        var title = text
        if let bold = text.firstMatch(of: /^\*\*(.+?)\*\*/) { title = String(bold.output.1) }
        title = title.replacingOccurrences(of: #"\*\*|__|`"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if title.hasSuffix(":") { title.removeLast() }
        // A file on its own: just its name.
        if title.contains("/"), !title.contains(" ") { title = (title as NSString).lastPathComponent }
        if title.count > 70, let end = title.range(of: ". ")?.lowerBound,
           title.distance(from: title.startIndex, to: end) >= 12 {
            title = String(title[..<end])
        }
        if title.count > 70 {
            let cut = title.prefix(70)
            title = (cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)) + "…"
        }
        return title.trimmingCharacters(in: .whitespaces)
    }
}
