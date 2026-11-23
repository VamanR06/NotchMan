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
        return ClaudePrompt(title: title.filter { !$0.isEmpty }, options: options)
    }

    /// "❯ 1. Red" / "  2. Green", each maybe followed by more-indented description lines; a rule may split the list.
    private static func numberedOptions(_ block: [String]) -> ([Option], Int)? {
        var found: [(line: Int, number: Int, label: String, selected: Bool, column: Int)] = []
        var index = block.count - 1
        while index >= 0 {
            let line = block[index]
            let text = line.trimmingCharacters(in: .whitespaces)
            if let option = numbered(line) {
                found.insert((index, option.number, option.label, option.selected, option.column), at: 0)
            } else if text.isEmpty || isRule(text) {
                // A gap or rule inside the list.
            } else if let lowest = found.first, indent(line) > lowest.column - 1, index > lowest.line - 4 {
                // A description under an option (more indented than its number).
            } else if found.isEmpty, indent(line) >= 3, index >= block.count - 3 {
                // A description under the last option.
            } else {
                break
            }
            index -= 1
        }
        guard found.count >= 2, found.contains(where: \.selected) else { return nil }
        var options: [Option] = []
        for (position, item) in found.enumerated() {
            let end = position + 1 < found.count ? found[position + 1].line : block.count
            let detail = block[(item.line + 1)..<end]
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !isRule($0) && $0 != item.label }
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
        func isSibling(_ line: String) -> Bool {
            indent(line) == column && !line.trimmingCharacters(in: .whitespaces).isEmpty
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

/// A view Claude opens over its input (a background task's details, the task list): a top border of "▔", its text, and
/// a footer of key hints ("← to go back · x to stop · Enter/Space to close · Esc to close"), turned into buttons.
struct ClaudePanel: Equatable {
    struct Action: Equatable, Identifiable {
        let label: String
        let keys: [UInt8]
        var id: String { label }
    }

    let lines: [String]
    let actions: [Action]

    static func parse(_ lines: [String]) -> ClaudePanel? {
        guard let footer = lines.lastIndex(where: { $0.contains("Esc to close") }),
              // Its top edge: a row of "▔", or the rule over Claude's input it replaced.
              let top = lines[..<footer].lastIndex(where: { ClaudePrompt.isRule($0.trimmingCharacters(in: .whitespaces)) })
        else { return nil }
        let body = lines[(top + 1)..<footer].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var actions: [Action] = []
        for hint in lines[footer].components(separatedBy: "·") {
            let parts = hint.trimmingCharacters(in: .whitespaces).components(separatedBy: " to ")
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces), action = parts[1].trimmingCharacters(in: .whitespaces)
            let bytes: [UInt8]? = switch key.lowercased() {
            case "esc": [0x1B]
            case "←": [0x1B, 0x5B, 0x44]
            case "enter", "enter/space": [0x0D]
            case "↑/↓": nil
            default: key.count == 1 ? Array(key.utf8) : nil
            }
            guard let bytes, !actions.contains(where: { $0.label.lowercased() == action.lowercased() }) else { continue }
            actions.append(Action(label: action.prefix(1).uppercased() + action.dropFirst(), keys: bytes))
        }
        if lines[footer].contains("↑/↓") {
            actions.insert(contentsOf: [Action(label: "↑", keys: [0x1B, 0x5B, 0x41]), Action(label: "↓", keys: [0x1B, 0x5B, 0x42])], at: 0)
        }
        return body.isEmpty ? nil : ClaudePanel(lines: body, actions: actions)
    }
}

/// A panel Claude opened, as a card: its text and a button per key hint.
struct ClaudePanelCard: View {
    let panel: ClaudePanel
    let press: ([UInt8]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(panel.lines.prefix(14).joined(separator: "\n"))
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            HStack(spacing: 6) {
                ForEach(panel.actions) { action in
                    Button(action.label) { press(action.keys) }
                        .controlSize(.small)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.12)))
    }
}

/// What Claude is waiting on, as a card above the message box: the question, an option per row (click to answer —
/// the same keys as in the terminal), and Cancel.
struct ClaudePromptCard: View {
    let prompt: ClaudePrompt
    let answer: (ClaudePrompt.Option) -> Void
    let cancel: () -> Void

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
            VStack(alignment: .leading, spacing: 2) {
                ForEach(prompt.options) { option in
                    PromptOptionRow(option: option) { answer(option) }
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
