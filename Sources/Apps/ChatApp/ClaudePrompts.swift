import NotchKit
import SwiftUI

/// A choice Claude Code is waiting on in its terminal: the folder-trust check, a question it asked (AskUserQuestion),
/// a permission prompt, a plan to approve — every one is a menu above a footer ending in "Esc to cancel". Read off
/// the screen, so whatever Claude Code asks shows in the session view, not just in the terminal.
struct ClaudePrompt: Equatable {
    struct Option: Equatable, Identifiable {
        /// Position in the menu, top to bottom.
        let index: Int
        /// The number Claude shows before it (pressing it answers), when it shows one.
        let number: Int?
        let label: String
        var detail: String?
        let isSelected: Bool
        var id: Int { index }

        /// "Type something." — picking it opens a text box in Claude's terminal; the message box types into it.
        var isTextEntry: Bool { label.lowercased().hasPrefix("type something") }
    }

    /// What it's asking: a heading and the question or explanation.
    let title: [String]
    let options: [Option]
    /// Other keys its footer offers ("s to use this session only"), beyond picking and cancelling.
    var extraKeys: [ClaudeKey] = []

    /// The keys that pick `option`: its number where Claude shows one; else arrows from the highlighted option, then
    /// Return.
    func keys(for option: Option) -> [UInt8] {
        if let number = option.number { return Array(String(number).utf8) }
        let current = options.first(where: \.isSelected)?.index ?? 0
        let delta = option.index - current
        let arrow: [UInt8] = delta > 0 ? [0x1B, 0x5B, 0x42] : [0x1B, 0x5B, 0x41]
        return Array(repeating: arrow, count: abs(delta)).flatMap { $0 } + [0x0D]
    }

    static let cancelKey: [UInt8] = [0x1B]

    // MARK: Reading the screen

    static func parse(_ lines: [String]) -> ClaudePrompt? {
        // The footer, at the bottom: "Enter to select · ↑/↓ to navigate · Esc to cancel", "Enter to confirm · Esc to cancel".
        guard let footer = lines.lastIndex(where: { $0.contains("Esc to cancel") }),
              lines[(footer + 1)...].filter({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }).count <= 2
        else { return nil }
        let block = Array(lines[..<footer])
        let options: [Option]
        let first: Int
        if let numbered = numberedOptions(block) {
            (options, first) = numbered
        } else if let plain = plainOptions(block) {
            (options, first) = plain
        } else {
            return nil
        }
        guard options.count >= 2 else { return nil }
        // The heading: the lines above the first option, up to the rule over the prompt.
        var title: [String] = []
        var index = first - 1
        while index >= 0, title.count < 10 {
            let text = block[index].trimmingCharacters(in: .whitespaces)
            if isRule(text) { break }
            if !text.isEmpty { title.insert(cleanTitle(text), at: 0) }
            index -= 1
        }
        let extra = ClaudeKey.hints(in: lines[footer]).filter { key in
            !key.keys.elementsEqual([0x1B]) && !key.keys.elementsEqual([0x0D]) && !["↑", "↓"].contains(key.label)
        }
        return ClaudePrompt(title: title.filter { !$0.isEmpty }, options: options, extraKeys: extra)
    }

    /// "❯ 1. Red" / "  2. Green", each maybe followed by more-indented description lines; a rule may split the list.
    private static func numberedOptions(_ block: [String]) -> ([Option], Int)? {
        // Numbered rows, plus rows without a number reached with the arrows (/model's "▸ More models" / "▾").
        var found: [(line: Int, number: Int?, label: String, selected: Bool, column: Int)] = []
        var index = block.count - 1
        var trailing = 0  // non-blank lines under the list before its last option
        while index >= 0 {
            let line = block[index]
            let text = line.trimmingCharacters(in: .whitespaces)
            if let option = numbered(line) {
                found.insert((index, option.number, option.label, option.selected, option.column), at: 0)
            } else if let row = line.firstMatch(of: /^(\s*)(❯\s*)?[▸▾→]\s+(.+)$/) {
                let column = row.output.1.count + (row.output.2.map(\.count) ?? 0)
                found.insert((index, nil, String(row.output.3).trimmingCharacters(in: .whitespaces), row.output.2 != nil, column), at: 0)
            } else if text.isEmpty || isRule(text) || text.firstMatch(of: /^[↑↓] \d+ more$/) != nil {
                // A gap, a rule, or a scroll marker ("↓ 6 more") inside the list.
            } else if let lowest = found.first, indent(line) > lowest.column - 1, index > lowest.line - 4 {
                // A description under an option (more indented than its number).
            } else if found.isEmpty, trailing < 4 {
                // A description under the last option, or extra lines under the list (/model's effort and
                // fast-mode lines).
                trailing += 1
            } else {
                break
            }
            index -= 1
        }
        guard found.filter({ $0.number != nil }).count >= 2, found.contains(where: \.selected) else { return nil }
        var options: [Option] = []
        for (position, item) in found.enumerated() {
            let end = position + 1 < found.count ? found[position + 1].line : block.count
            let detail = block[(item.line + 1)..<end]
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !isRule($0) && $0 != item.label && $0.firstMatch(of: /^[↑↓] \d+ more$/) == nil }
                .joined(separator: " ")
            options.append(Option(index: position, number: item.number, label: item.label,
                                  detail: detail.isEmpty ? nil : detail, isSelected: item.selected))
        }
        return (options, found[0].line)
    }

    /// "❯ No, exit" / "  Yes, I trust this folder": no numbers, the options' text lined up in one column.
    private static func plainOptions(_ block: [String]) -> ([Option], Int)? {
        guard let marked = block.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("❯ ") }),
              let marker = block[marked].firstIndex(of: "❯") else { return nil }
        let column = block[marked].distance(from: block[marked].startIndex, to: marker) + 2
        // "❯ ✔ Auto" puts the current choice's mark where the others' text starts.
        let marked2 = block[marked].dropFirst(column).hasPrefix("✔ ")
        func isSibling(_ line: String) -> Bool {
            !line.trimmingCharacters(in: .whitespaces).isEmpty && (indent(line) == column || (marked2 && indent(line) == column + 2))
        }
        func isBlank(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces).isEmpty }
        // Siblings above and below, across blank lines (the rewind list spaces its entries out).
        var lines = [marked]
        var index = marked - 1
        while index >= 0, isSibling(block[index]) || isBlank(block[index]) {
            if !isBlank(block[index]) { lines.insert(index, at: 0) }
            index -= 1
        }
        index = marked + 1
        while index < block.count, isSibling(block[index]) || isBlank(block[index]) {
            if !isBlank(block[index]) { lines.append(index) }
            index += 1
        }
        guard lines.count >= 2 else { return nil }
        var options: [Option] = []
        for line in lines {
            let text = block[line].trimmingCharacters(in: .whitespaces)
            let selected = line == marked
            // In the rewind list each prompt has a line under it saying what code changed since: that's its detail.
            if !selected, let last = options.last, last.detail == nil, isChangeSummary(text) {
                options[options.count - 1].detail = text
                continue
            }
            options.append(Option(index: options.count, number: nil,
                                  label: selected ? String(text.dropFirst(2)).trimmingCharacters(in: .whitespaces) : text,
                                  detail: nil, isSelected: selected))
        }
        guard options.count >= 2 else { return nil }
        return (options, lines[0])
    }

    private static func numbered(_ line: String) -> (number: Int, label: String, selected: Bool, column: Int)? {
        guard let match = line.firstMatch(of: /^(\s*)(❯\s*)?(\d{1,2})\.\s+(.+)$/) else { return nil }
        let column = match.output.1.count + (match.output.2.map(\.count) ?? 0)
        return (Int(match.output.3) ?? 0, String(match.output.4).trimmingCharacters(in: .whitespaces),
                match.output.2 != nil, column)
    }

    private static func indent(_ line: String) -> Int { line.prefix { $0 == " " }.count }

    /// "No code changes", "2 files changed +14 -3".
    static func isChangeSummary(_ text: String) -> Bool {
        text == "No code changes" || text.firstMatch(of: /^\d+ files? changed/) != nil
    }

    /// Esc twice from an idle input box: Claude's rewind list.
    static let rewindKeys: [UInt8] = [0x1B, 0x1B]

    static func isRule(_ text: String) -> Bool {
        text.count >= 8 && text.allSatisfy { "─━═╌┄▔▁-".contains($0) }
    }

    /// "☐ Color" → "Color" (AskUserQuestion's tab), and the box-drawing frame some prompts sit in.
    private static func cleanTitle(_ text: String) -> String {
        var text = text.trimmingCharacters(in: CharacterSet(charactersIn: "│╭╮╰╯ "))
        for mark in ["☐ ", "☑ ", "✔ ", "□ "] where text.hasPrefix(mark) { text.removeFirst(mark.count) }
        return text.trimmingCharacters(in: .whitespaces)
    }
}

/// Claude Code's permission mode, from its footer: "⏵⏵ auto mode on (shift+tab to cycle)", "⏸ manual mode on · ? for
/// shortcuts", "⏵⏵ accept edits on · 1 shell". Shift-Tab goes Auto → Manual → Accept edits → Plan → Auto.
enum ClaudeMode {
    static let cycleKey: [UInt8] = [0x1B, 0x5B, 0x5A]

    static func parse(_ lines: [String]) -> String? {
        for line in lines.suffix(6).reversed() {
            guard let match = line.firstMatch(of: /([A-Za-z][A-Za-z ]*?(?: mode| edits| permissions)) on\b/) else { continue }
            let mode = String(match.output.1).trimmingCharacters(in: .whitespaces)
            return mode.prefix(1).uppercased() + mode.dropFirst()
        }
        return nil
    }
}

/// What Claude's footer says is running in the background ("1 shell · ← 1 agent · ↓ to manage").
enum ClaudeFooter {
    /// Background shells still running; ↓ from an empty input box highlights "enter to view tasks", then Return opens it.
    static func shells(_ lines: [String]) -> Int {
        for line in lines.suffix(6).reversed() {
            if let match = line.firstMatch(of: /(\d+) shells?\b/) { return Int(match.output.1) ?? 0 }
        }
        return 0
    }

    static let manageKeys: [[UInt8]] = [[0x1B, 0x5B, 0x42], [0x0D]]
}

/// The keys a footer hint names ("Esc to close", "←/→ to switch", "s to use this session only"), as buttons.
struct ClaudeKey: Equatable, Identifiable {
    let label: String
    /// What it does, for the tooltip.
    let help: String
    let keys: [UInt8]
    var id: String { label + help }

    static let up: [UInt8] = [0x1B, 0x5B, 0x41], down: [UInt8] = [0x1B, 0x5B, 0x42]
    static let left: [UInt8] = [0x1B, 0x5B, 0x44], right: [UInt8] = [0x1B, 0x5B, 0x43]

    /// Every "KEY to ACTION" in a footer, in order. Arrows become one button each way.
    static func hints(in footer: String) -> [ClaudeKey] {
        var keys: [ClaudeKey] = []
        for hint in footer.components(separatedBy: "·") {
            let text = hint.trimmingCharacters(in: .whitespaces)
            guard let range = text.range(of: " to ") else { continue }
            let key = String(text[..<range.lowerBound]), action = String(text[range.upperBound...])
            let title = action.prefix(1).uppercased() + action.dropFirst()
            switch key.lowercased() {
            case "↑/↓": keys += [ClaudeKey(label: "↑", help: title, keys: up), ClaudeKey(label: "↓", help: title, keys: down)]
            case "←/→": keys += [ClaudeKey(label: "←", help: title, keys: left), ClaudeKey(label: "→", help: title, keys: right)]
            case "↑": keys.append(ClaudeKey(label: "↑", help: title, keys: up))
            case "↓": keys.append(ClaudeKey(label: "↓", help: title, keys: down))
            case "←": keys.append(ClaudeKey(label: title, help: "←", keys: left))
            case "→": keys.append(ClaudeKey(label: title, help: "→", keys: right))
            case "esc": keys.append(ClaudeKey(label: title, help: "Esc", keys: [0x1B]))
            case "enter", "enter/space": keys.append(ClaudeKey(label: title, help: "Return", keys: [0x0D]))
            case "space": keys.append(ClaudeKey(label: title, help: "Space", keys: [0x20]))
            case "tab": keys.append(ClaudeKey(label: title, help: "Tab", keys: [0x09]))
            default:
                if key.lowercased().hasPrefix("ctrl+"), let letter = key.lowercased().last, let ascii = letter.asciiValue, letter.isLetter {
                    keys.append(ClaudeKey(label: title, help: key, keys: [ascii - 96]))
                } else if key.count == 1 {
                    keys.append(ClaudeKey(label: title, help: key, keys: Array(key.utf8)))
                }
            }
        }
        var seen = Set<String>()
        return keys.filter { seen.insert($0.label).inserted }  // "Enter/Space to close" and "Esc to close": one Close
    }
}

/// Any screen Claude Code opens over its input — /model, /config, /permissions, /mcp, /memory, /hooks, /status, /usage,
/// /effort, /theme, /export, /resume, a background task — read off the terminal: a "▔" top edge (or the rule over the
/// input it replaced), its lines, and a footer of key hints. Shown as a card that mirrors it: rows to click (the
/// highlighted "❯" one and its siblings), and a button per hint.
struct ClaudeScreen: Equatable {
    struct Line: Equatable, Identifiable {
        let id: Int
        let text: String
        /// A row of the highlighted list: clicking moves the highlight here, then presses Return.
        var row: Int?
        var isSelected = false
    }

    let lines: [Line]
    let keys: [ClaudeKey]

    var title: String? { lines.first?.text.trimmingCharacters(in: .whitespaces) }

    /// The keys that pick row `row`: arrows from the highlighted row, then Return.
    func keys(forRow row: Int) -> [UInt8] {
        let current = lines.first(where: \.isSelected)?.row ?? 0
        let delta = row - current
        return Array(repeating: delta > 0 ? ClaudeKey.down : ClaudeKey.up, count: abs(delta)).flatMap { $0 } + [0x0D]
    }

    static func parse(_ screen: [String]) -> ClaudeScreen? {
        let nonEmpty = screen.indices.filter { !screen[$0].trimmingCharacters(in: .whitespaces).isEmpty }
        // The footer: one of the last lines, made of key hints ("↑/↓ to navigate · Enter to select · Esc to close").
        guard let footer = nonEmpty.suffix(3).last(where: { isFooter(screen[$0]) }) else { return nil }
        guard let top = screen[..<footer].lastIndex(where: { line in
            line.filter { $0 == "▔" }.count >= 20 || ClaudePrompt.isRule(line.trimmingCharacters(in: .whitespaces))
        }) else { return nil }
        var body = screen[(top + 1)..<footer].map { line -> String in
            var text = line
            while text.last == " " { text.removeLast() }
            return text
        }
        while body.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { body.removeFirst() }
        while body.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { body.removeLast() }
        guard !body.isEmpty else { return nil }
        // Common indent off, blank runs folded to one.
        let indent = body.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { $0.prefix { $0 == " " }.count }.min() ?? 0
        var trimmed: [String] = []
        for line in body {
            let text = String(line.dropFirst(min(indent, line.prefix { $0 == " " }.count)))
            if text.isEmpty, trimmed.last?.isEmpty == true { continue }
            trimmed.append(text)
        }
        var lines = trimmed.enumerated().map { Line(id: $0.offset, text: $0.element) }
        // The highlighted list: the "❯" line with the most siblings (lines whose text starts in its column).
        var best: [Int] = []
        var bestSelected: Int?
        for (index, line) in trimmed.enumerated() {
            guard let marker = line.firstIndex(of: "❯"), line[..<marker].allSatisfy({ $0 == " " }) else { continue }
            let markerColumn = line.distance(from: line.startIndex, to: marker)
            let afterMarker = line[line.index(after: marker)...].drop { $0 == " " }
            let column = line.distance(from: line.startIndex, to: afterMarker.startIndex)
            func isSibling(_ other: String) -> Bool {
                let lead = other.prefix { $0 == " " }.count
                guard lead < other.count, !other.dropFirst(lead).hasPrefix("❯") else { return false }
                return lead == column || lead == markerColumn + 2 || lead == column + 2
            }
            var rows = [index]
            var up = index - 1
            while up >= 0, isSibling(trimmed[up]) || trimmed[up].isEmpty { if !trimmed[up].isEmpty { rows.insert(up, at: 0) }; up -= 1 }
            var down = index + 1
            while down < trimmed.count, isSibling(trimmed[down]) || trimmed[down].isEmpty { if !trimmed[down].isEmpty { rows.append(down) }; down += 1 }
            if rows.count > best.count { best = rows; bestSelected = index }
        }
        for (row, index) in best.enumerated() {
            lines[index].row = row
            lines[index].isSelected = index == bestSelected
        }
        return ClaudeScreen(lines: lines, keys: ClaudeKey.hints(in: screen[footer]))
    }

    /// A footer of key hints, not Claude's ordinary footer under its input ("esc to interrupt", "? for shortcuts").
    static func isFooter(_ line: String) -> Bool {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard text.contains(" to "), !text.contains("shift+tab"), !text.contains("? for shortcuts"),
              !text.contains("esc to interrupt") else { return false }
        return text.contains("Esc to") || text.contains("Enter to") || text.contains("to navigate")
            || text.contains("to switch") || text.contains("to close")
    }
}

/// A Claude Code screen as a card: its text with the list rows clickable, and a button per key hint. Tall screens
/// scroll inside the card.
struct ClaudeScreenCard: View {
    let screen: ClaudeScreen
    let press: ([UInt8]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(screen.lines) { line in
                            if let row = line.row {
                                ScreenRow(text: line.text, isSelected: line.isSelected) { press(screen.keys(forRow: row)) }
                                    .id(line.id)
                            } else {
                                Text(line.text.isEmpty ? " " : line.text)
                                    .font(.system(size: 11, weight: line.id == 0 ? .semibold : .regular, design: .monospaced))
                                    .foregroundStyle(.white.opacity(line.id == 0 ? 0.95 : 0.7))
                                    .lineLimit(1).truncationMode(.tail)
                                    .padding(.horizontal, 6)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
                .fixedSize(horizontal: false, vertical: true)
                .onAppear { if let selected = screen.lines.first(where: \.isSelected) { proxy.scrollTo(selected.id, anchor: .center) } }
            }
            HStack(spacing: 6) {
                ForEach(screen.keys) { key in
                    Button(key.label) { press(key.keys) }
                        .controlSize(.small)
                        .help(key.help)
                }
                Spacer(minLength: 0)
                Label("Keyboard works too", systemImage: "keyboard").font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.09)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.12)))
    }
}

private struct ScreenRow: View {
    let text: String
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(text.replacingOccurrences(of: "❯", with: " "))
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular, design: .monospaced))
                .foregroundStyle(.white.opacity(0.95))
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(isSelected ? Color.accentColor.opacity(0.35) : .white.opacity(hovering ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// What Claude is waiting on, as a card above the message box: the question, an option per row (click to answer —
/// the same keys as in the terminal), and Cancel.
struct ClaudePromptCard: View {
    let prompt: ClaudePrompt
    let answer: (ClaudePrompt.Option) -> Void
    let cancel: () -> Void
    /// Any other key the prompt offers.
    var press: ([UInt8]) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "questionmark.bubble.fill").font(.system(size: 11)).foregroundStyle(.orange)
                Text(prompt.title.first ?? "Claude is asking").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white).lineLimit(2)
                Spacer(minLength: 6)
                Button("Cancel", action: cancel)
                    .buttonStyle(.plain).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.5))
                    .help("Esc in Claude's terminal")
            }
            if prompt.title.count > 1 {
                Text(prompt.title.dropFirst().joined(separator: " "))
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                    .lineLimit(4).fixedSize(horizontal: false, vertical: true)
            }
            // A long list (the rewind list grows with every prompt) scrolls inside the card.
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(prompt.options) { option in
                            PromptOptionRow(option: option) { answer(option) }.id(option.id)
                        }
                    }
                }
                .frame(maxHeight: 220)
                .fixedSize(horizontal: false, vertical: true)
                .onAppear { if let selected = prompt.options.first(where: \.isSelected) { proxy.scrollTo(selected.id, anchor: .center) } }
            }
            if !prompt.extraKeys.isEmpty {
                HStack(spacing: 6) {
                    ForEach(prompt.extraKeys) { key in
                        Button(key.label) { press(key.keys) }.controlSize(.small).help(key.help)
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.25)))
    }
}

private struct PromptOptionRow: View {
    let option: ClaudePrompt.Option
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(option.number.map { "\($0)" } ?? "•")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(width: 14, alignment: .trailing)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label).font(.system(size: 11.5, weight: option.isSelected ? .semibold : .regular))
                        .foregroundStyle(.white.opacity(0.95))
                    if let detail = option.detail {
                        Text(detail).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.5)).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                if option.isTextEntry {
                    Text("then type below").font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.4))
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(hovering ? 0.1 : option.isSelected ? 0.05 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
