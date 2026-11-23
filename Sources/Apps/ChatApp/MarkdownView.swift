import AppKit
import SwiftUI

/// Markdown as Claude writes it, split into blocks: headings, paragraphs (wrapped lines joined), lists (nested,
/// numbered, checkboxes), code, quotes, tables and rules. Inline styling is left to `MarkdownView.inline`.
struct MarkdownDocument: Equatable {
    enum Alignment: Equatable { case leading, center, trailing }

    struct ListItem: Equatable {
        /// "•", "3.", "☐" or "☑".
        var marker: String
        var text: String
        var depth: Int
    }

    enum Block: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case list([ListItem])
        case code(language: String?, text: String)
        case quote(String)
        case table(header: [String], alignments: [Alignment], rows: [[String]])
        case rule
    }

    var blocks: [Block]

    static func parse(_ text: String) -> MarkdownDocument {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [Block] = []
        var paragraph: [String] = []
        var list: [ListItem] = []
        var quote: [String] = []
        var index = 0

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
            if !list.isEmpty { blocks.append(.list(list)); list = [] }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: " "))); quote = [] }
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }

            // Code fence: everything up to the closing fence, as is.
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                let fence = String(trimmed.prefix(3))
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[index])
                    index += 1
                }
                blocks.append(.code(language: language.isEmpty ? nil : language, text: code.joined(separator: "\n")))
                index += 1
                continue
            }
            // Table: a row of cells, then a separator row of dashes.
            if trimmed.contains("|"), index + 1 < lines.count, let alignments = separatorRow(lines[index + 1]) {
                flush()
                let header = cells(trimmed)
                var rows: [[String]] = []
                index += 2
                while index < lines.count {
                    let row = lines[index].trimmingCharacters(in: .whitespaces)
                    guard row.contains("|"), !row.isEmpty else { break }
                    rows.append(cells(row))
                    index += 1
                }
                let width = max(header.count, alignments.count)
                blocks.append(.table(header: pad(header, to: width),
                                     alignments: pad(alignments, to: width, with: .leading),
                                     rows: rows.map { pad($0, to: width) }))
                continue
            }
            if trimmed.isEmpty {
                flush()
            } else if let level = headingLevel(trimmed) {
                flush()
                blocks.append(.heading(level: level, text: String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "#")).trimmingCharacters(in: .whitespaces)))
            } else if trimmed.range(of: #"^([-*_])(\s*\1){2,}$"#, options: .regularExpression) != nil {
                flush()
                blocks.append(.rule)
            } else if let item = listItem(trimmed, indent: indent) {
                if !paragraph.isEmpty || !quote.isEmpty {
                    let pending = list
                    list = []
                    flush()
                    list = pending
                }
                list.append(item)
            } else if trimmed.hasPrefix(">") {
                if !paragraph.isEmpty || !list.isEmpty { flush() }
                quote.append(String(trimmed.drop { $0 == ">" }).trimmingCharacters(in: .whitespaces))
            } else if !list.isEmpty, indent >= 2 {
                // A wrapped list item continues on an indented line.
                list[list.count - 1].text += " " + trimmed
            } else {
                if !list.isEmpty || !quote.isEmpty { flush() }
                paragraph.append(trimmed)
            }
            index += 1
        }
        flush()
        return MarkdownDocument(blocks: blocks)
    }

    static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.count > hashes, line[line.index(line.startIndex, offsetBy: hashes)] == " " else { return nil }
        return hashes
    }

    static func listItem(_ line: String, indent: Int) -> ListItem? {
        let depth = indent / 2
        for (prefix, marker) in [("- [ ] ", "☐"), ("- [x] ", "☑"), ("- [X] ", "☑"), ("* [ ] ", "☐"), ("* [x] ", "☑")]
        where line.hasPrefix(prefix) {
            return ListItem(marker: marker, text: String(line.dropFirst(prefix.count)), depth: depth)
        }
        if let bullet = ["- ", "* ", "+ ", "• "].first(where: line.hasPrefix) {
            return ListItem(marker: "•", text: String(line.dropFirst(bullet.count)), depth: depth)
        }
        if let match = line.range(of: #"^[0-9]{1,3}[.)]\s"#, options: .regularExpression) {
            let marker = line[match].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ")", with: ".")
            return ListItem(marker: marker, text: String(line[match.upperBound...]), depth: depth)
        }
        return nil
    }

    /// `| a | b |` → ["a", "b"] (outer pipes optional, `\|` kept as a pipe).
    static func cells(_ row: String) -> [String] {
        var text = row.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|") && !text.hasSuffix("\\|") { text.removeLast() }
        let placeholder = "\u{0}"
        return text.replacingOccurrences(of: "\\|", with: placeholder).components(separatedBy: "|")
            .map { $0.replacingOccurrences(of: placeholder, with: "|").trimmingCharacters(in: .whitespaces) }
    }

    /// `|---|:--:|--:|` → alignments, or nil when the line isn't a table's separator row.
    static func separatorRow(_ line: String) -> [Alignment]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.contains("|") || trimmed.hasPrefix(":") || trimmed.hasPrefix("-") else { return nil }
        let parts = cells(trimmed)
        guard !parts.isEmpty, parts.allSatisfy({ $0.range(of: #"^:?-{1,}:?$"#, options: .regularExpression) != nil }) else { return nil }
        return parts.map { part in
            switch (part.hasPrefix(":"), part.hasSuffix(":")) {
            case (true, true): .center
            case (false, true): .trailing
            default: .leading
            }
        }
    }

    private static func pad<T>(_ items: [T], to count: Int, with filler: T) -> [T] {
        items.count >= count ? Array(items.prefix(count)) : items + Array(repeating: filler, count: count - items.count)
    }

    private static func pad(_ items: [String], to count: Int) -> [String] { pad(items, to: count, with: "") }
}

/// Draws Markdown with the notch's look. Parsing is kept per text, so long sessions scroll smoothly.
struct MarkdownView: View {
    let text: String
    var size: CGFloat = 12.5
    /// Set in a session: commands in the text can be ⌘-clicked to run.
    @Environment(\.commandRunner) private var runner

    var body: some View {
        let document = MarkdownCache.document(for: text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { url in
            guard let command = ShellCommand.command(from: url) else { return .systemAction }
            runner?.click(command)
            return .handled
        })
    }

    private func inline(_ text: String) -> AttributedString {
        Self.inline(text, size: size, commands: runner != nil)
    }

    @ViewBuilder private func view(for block: MarkdownDocument.Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .font(.system(size: level == 1 ? size + 3 : level == 2 ? size + 1.5 : size, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.top, level <= 2 ? 4 : 0)
        case .paragraph(let text):
            Text(inline(text))
                .font(.system(size: size))
                .foregroundStyle(.white.opacity(0.9))
                .lineSpacing(2.5)
                .fixedSize(horizontal: false, vertical: true)
        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(item.marker)
                            .font(.system(size: size, weight: item.marker == "•" ? .bold : .regular).monospacedDigit())
                            .foregroundStyle(item.marker == "☑" ? Color.green : .white.opacity(0.5))
                            .frame(minWidth: 12, alignment: .trailing)
                        Text(inline(item.text))
                            .font(.system(size: size))
                            .foregroundStyle(.white.opacity(item.marker == "☑" ? 0.55 : 0.9))
                            .lineSpacing(2.5)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.depth) * 16)
                }
            }
        case .code(let language, let text):
            CodeBlock(language: language, text: text)
        case .quote(let text):
            Text(inline(text))
                .font(.system(size: size))
                .foregroundStyle(.white.opacity(0.65))
                .padding(.leading, 10)
                .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 1).fill(.white.opacity(0.25)).frame(width: 2) }
        case .table(let header, let alignments, let rows):
            MarkdownTable(header: header, alignments: alignments, rows: rows, size: size)
        case .rule:
            Divider().overlay(.white.opacity(0.15))
        }
    }

    /// Bold, italic, links, strikethrough and `code` within a line; code in a monospaced face and a warm tint.
    /// With `commands`, code that reads as a shell command becomes a `notchman-run:` link (⌘-click runs it).
    static func inline(_ text: String, size: CGFloat, commands: Bool = false) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var string = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        for run in string.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                string[run.range].font = .system(size: size - 0.5, design: .monospaced)
                string[run.range].foregroundColor = Color(red: 1, green: 0.78, blue: 0.55)
                if commands, let command = ShellCommand.inline(String(string[run.range].characters)),
                   let link = ShellCommand.link(for: command) {
                    string[run.range].link = link
                    string[run.range].underlineStyle = Text.LineStyle(pattern: .dot, color: Color(red: 1, green: 0.78, blue: 0.55).opacity(0.5))
                }
                continue
            }
            if run.link != nil {
                string[run.range].foregroundColor = .accentColor
            }
        }
        return string
    }
}

/// A fenced code block: monospaced, scrolls sideways instead of wrapping, with its language and a copy button.
/// Shell commands in a session also get Run (⌘-click the block does the same; ⌥ runs them in Terminal).
private struct CodeBlock: View {
    let language: String?
    let text: String
    @State private var copied = false
    @State private var hovering = false
    @Environment(\.commandRunner) private var runner

    private var command: String? { runner == nil ? nil : ShellCommand.block(text, language: language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(language ?? "code").font(.system(size: 9.5, weight: .medium)).foregroundStyle(.white.opacity(0.4))
                Spacer()
                if let command, let runner {
                    Button {
                        if NSEvent.modifierFlags.contains(.option) { runner.runInTerminal(command) } else { runner.run(command) }
                    } label: {
                        Label("Run", systemImage: "play.fill").font(.system(size: 9.5))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(hovering ? 0.7 : 0.35))
                    .help("Run in a shell in the project (⌥-click: in Terminal) — or ⌘-click the block")
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 9.5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(hovering || copied ? 0.7 : 0.35))
            }
            .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 4)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineSpacing(2)
                    .fixedSize()
                    .padding(.horizontal, 10).padding(.bottom, 8)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.06)))
        .onHover { hovering = $0 }
        .commandMenu(command)
        .simultaneousGesture(TapGesture().modifiers(.command).onEnded {
            if let command, let runner { runner.click(command) }
        })
    }
}

/// A Markdown table: a bold header, light row lines, cells aligned as the separator row says, and sideways scrolling
/// when it's wider than the space.
private struct MarkdownTable: View {
    let header: [String]
    let alignments: [MarkdownDocument.Alignment]
    let rows: [[String]]
    let size: CGFloat

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 0) {
                GridRow {
                    ForEach(header.indices, id: \.self) { column in
                        cell(header[column], column: column, bold: true)
                    }
                }
                .padding(.vertical, 5)
                Divider().overlay(.white.opacity(0.2)).gridCellUnsizedAxes(.horizontal)
                ForEach(rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(header.indices, id: \.self) { column in
                            cell(rows[row][column], column: column, bold: false)
                        }
                    }
                    .padding(.vertical, 4)
                    if row < rows.count - 1 {
                        Divider().overlay(.white.opacity(0.07)).gridCellUnsizedAxes(.horizontal)
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            // The box fits the table; a wide table scrolls sideways inside the space.
            .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.035)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.07)))
        }
    }

    private func cell(_ text: String, column: Int, bold: Bool) -> some View {
        Text(MarkdownView.inline(text, size: size - 0.5))
            .font(.system(size: size - 0.5, weight: bold ? .semibold : .regular))
            .foregroundStyle(.white.opacity(bold ? 0.95 : 0.85))
            .frame(maxWidth: 260, alignment: frameAlignment(column))
            .fixedSize(horizontal: false, vertical: true)
            .gridColumnAlignment(gridAlignment(column))
    }

    private func frameAlignment(_ column: Int) -> SwiftUI.Alignment {
        switch alignments[column] {
        case .center: .center
        case .trailing: .trailing
        case .leading: .leading
        }
    }

    private func gridAlignment(_ column: Int) -> HorizontalAlignment {
        switch alignments[column] {
        case .center: .center
        case .trailing: .trailing
        case .leading: .leading
        }
    }
}

/// Parsed documents by text, so redrawing a long session doesn't parse every reply again.
@MainActor
enum MarkdownCache {
    private static var documents: [String: MarkdownDocument] = [:]

    static func document(for text: String) -> MarkdownDocument {
        if let cached = documents[text] { return cached }
        if documents.count > 400 { documents.removeAll() }
        let document = MarkdownDocument.parse(text)
        documents[text] = document
        return document
    }
}
