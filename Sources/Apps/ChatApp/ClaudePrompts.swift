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
        var lines = [marked]
        var index = marked - 1
        while index >= 0, isSibling(block[index]) { lines.insert(index, at: 0); index -= 1 }
        index = marked + 1
        while index < block.count, isSibling(block[index]) { lines.append(index); index += 1 }
        guard lines.count >= 2 else { return nil }
        let options = lines.enumerated().map { position, line in
            let text = block[line].trimmingCharacters(in: .whitespaces)
            let selected = line == marked
            return Option(index: position, number: nil,
                          label: selected ? String(text.dropFirst(2)).trimmingCharacters(in: .whitespaces) : text,
                          detail: nil, isSelected: selected)
        }
        return (options, lines[0])
    }

    private static func numbered(_ line: String) -> (number: Int, label: String, selected: Bool, column: Int)? {
        guard let match = line.firstMatch(of: /^(\s*)(❯\s*)?(\d{1,2})\.\s+(.+)$/) else { return nil }
        let column = match.output.1.count + (match.output.2.map(\.count) ?? 0)
        return (Int(match.output.3) ?? 0, String(match.output.4).trimmingCharacters(in: .whitespaces),
                match.output.2 != nil, column)
    }

    private static func indent(_ line: String) -> Int { line.prefix { $0 == " " }.count }

    static func isRule(_ text: String) -> Bool {
        text.count >= 8 && text.allSatisfy { "─━═╌┄-".contains($0) }
    }

    /// "☐ Color" → "Color" (AskUserQuestion's tab), and the box-drawing frame some prompts sit in.
    private static func cleanTitle(_ text: String) -> String {
        var text = text.trimmingCharacters(in: CharacterSet(charactersIn: "│╭╮╰╯ "))
        for mark in ["☐ ", "☑ ", "✔ ", "□ "] where text.hasPrefix(mark) { text.removeFirst(mark.count) }
        return text.trimmingCharacters(in: .whitespaces)
    }
}

/// Claude Code's permission mode, from its footer ("⏵⏵ auto mode on (shift+tab to cycle)"); Shift-Tab changes it.
enum ClaudeMode {
    static let cycleKey: [UInt8] = [0x1B, 0x5B, 0x5A]

    static func parse(_ lines: [String]) -> String? {
        for line in lines.suffix(6).reversed() {
            guard let range = line.range(of: "(shift+tab to cycle)") else { continue }
            let mode = line[..<range.lowerBound]
                .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "⏵⏸·")))
                .replacingOccurrences(of: " on", with: "")
            return mode.isEmpty ? nil : mode.prefix(1).uppercased() + mode.dropFirst()
        }
        return nil
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
