import AppKit
import NotchKit
import SwiftUI
import UniformTypeIdentifiers

/// A file mentioned in terminal output, resolved to one that exists.
struct FileMention: Equatable {
    let url: URL
    /// From a `path:12` or `path:12:4` suffix.
    let line: Int?
}

/// Finding the file path under a ⌘-click in terminal text.
enum FileMentions {
    /// Characters a path can contain (plus `:` for a line number). Spaces, quotes, brackets, commas and `=` end
    /// it, so `Update(src/a.swift)`, "`a.swift`, `b.swift`" and `--file=a.swift` give just the path.
    static func isPathCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || "_-./~+@%:".contains(character)
    }

    /// The path-like word around `column` in a row of terminal cells, without trailing sentence punctuation.
    static func token(in cells: [Character], at column: Int) -> String? {
        guard cells.indices.contains(column), isPathCharacter(cells[column]) else { return nil }
        var start = column
        var end = column
        while start > 0, isPathCharacter(cells[start - 1]) { start -= 1 }
        while end + 1 < cells.count, isPathCharacter(cells[end + 1]) { end += 1 }
        var token = String(cells[start...end])
        while let last = token.last, ".:".contains(last) { token.removeLast() }
        while token.first == ":" { token.removeFirst() }
        return token.isEmpty ? nil : token
    }

    /// Splits a `path:line[:column]` suffix off.
    static func split(_ token: String) -> (path: String, line: Int?) {
        guard let match = token.range(of: #":[0-9]+(:[0-9]+)?$"#, options: .regularExpression) else {
            return (token, nil)
        }
        let digits = token[match].dropFirst().prefix { $0.isNumber }
        return (String(token[..<match.lowerBound]), Int(digits))
    }

    /// The existing file or folder `token` names: absolute, `~/…`, `file://…`, or relative to `directory`.
    static func resolve(_ token: String, in directory: String?, fileManager: FileManager = .default) -> FileMention? {
        var token = token
        if token.hasPrefix("file://") {
            guard let path = URL(string: token)?.path, !path.isEmpty else { return nil }
            token = path
        } else if token.contains("://") {
            return nil
        }
        let (path, line) = split(token)
        guard !path.isEmpty else { return nil }
        let url: URL
        if path.hasPrefix("/") || path.hasPrefix("~") {
            url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        } else if let directory {
            url = URL(fileURLWithPath: directory).appendingPathComponent(path)
        } else {
            return nil
        }
        let standardized = url.standardizedFileURL
        guard fileManager.fileExists(atPath: standardized.path) else { return nil }
        return FileMention(url: standardized, line: line)
    }
}

/// A file clicked in terminal output, previewed in a pane over the terminal.
struct FilePreview: Identifiable {
    enum Content: Equatable {
        /// Source and plain text, with line numbers (and the mentioned line marked).
        case text([String], truncated: Bool)
        case markdown([String], truncated: Bool)
        case folder([String])
        /// Everything else macOS can preview: PDFs, images, video, Office documents, archives, …
        case quickLook
        case unavailable(String)
    }

    let id = UUID()
    let url: URL
    let line: Int?
    let content: Content

    init(mention: FileMention) {
        url = mention.url
        line = mention.line
        content = Self.load(mention.url)
    }

    /// Enough of a file to preview: big files are cut off.
    static let maxBytes = 512 * 1024

    static func load(_ url: URL) -> Content {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentTypeKey, .fileSizeKey])
        if values?.isDirectory == true {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            return .folder(names.filter { !$0.hasPrefix(".") }.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        }
        if let type = values?.contentType, Self.quickLookTypes.contains(where: type.conforms) { return .quickLook }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unavailable("Can't read this file.") }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxBytes)) ?? Data()
        // Not text: let Quick Look show it (it has a preview for most kinds, and a file summary for the rest).
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else { return .quickLook }
        let truncated = (values?.fileSize ?? 0) > maxBytes
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let isMarkdown = ["md", "markdown", "mdx"].contains(url.pathExtension.lowercased())
        return isMarkdown ? .markdown(lines, truncated: truncated) : .text(lines, truncated: truncated)
    }

    /// Shown by Quick Look even when they're text inside (SVG, RTF), since its rendering is what you'd want.
    static let quickLookTypes: [UTType] = [.image, .pdf, .audiovisualContent, .presentation, .spreadsheet, .rtf, .rtfd]
}

/// The preview as a pane over the whole terminal (Esc or ✕ closes it; the terminal keeps running underneath).
struct FilePreviewOverlay: View {
    let preview: FilePreview
    let close: () -> Void

    var body: some View {
        FilePreviewCard(preview: preview, close: close)
            .padding(4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.35).onTapGesture(perform: close))
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }
}

/// File name, path and actions, then the file's contents.
private struct FilePreviewCard: View {
    let preview: FilePreview
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(.white.opacity(0.12))
            content
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.1)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.18)))
        .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: preview.url.path))
                .resizable()
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(preview.url.lastPathComponent + (preview.line.map { ":\($0)" } ?? ""))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Text(NSString(string: preview.url.deletingLastPathComponent().path).abbreviatingWithTildeInPath)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
                    .truncationMode(.middle)
            }
            .lineLimit(1)
            Spacer(minLength: 4)
            button("arrow.up.forward.app", help: "Open in its app") {
                NSWorkspace.shared.open(preview.url)
                close()
            }
            button("folder", help: "Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([preview.url])
                close()
            }
            button("eye", help: "Quick Look (full size)") {
                QuickLookPanel.show([preview.url])
            }
            button("doc.on.doc", help: "Copy path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(preview.url.path, forType: .string)
            }
            button("xmark", help: "Close (Esc)", action: close)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func button(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.7))
        .help(help)
    }

    @ViewBuilder private var content: some View {
        switch preview.content {
        case .text(let lines, let truncated):
            CodeLines(lines: lines, highlight: preview.line, truncated: truncated)
        case .markdown(let lines, let truncated):
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    MarkdownView(text: lines.joined(separator: "\n"))
                    if truncated {
                        Text("Preview cut off — open the file to see the rest.")
                            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                    }
                }
                .padding(14)
            }
        case .quickLook:
            QuickLookPreview(url: preview.url)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .folder(let names):
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    if names.isEmpty { note("Empty folder.") }
                    ForEach(names, id: \.self) { name in
                        Text(name).font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.85))
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .unavailable(let reason):
            note(reason).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
    }
}

/// Source text with line numbers, scrolled to (and marking) the mentioned line.
private struct CodeLines: View {
    let lines: [String]
    let highlight: Int?
    let truncated: Bool

    var body: some View {
        let gutter = CGFloat(String(lines.count).count) * 7 + 6
        ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines.indices, id: \.self) { index in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(index + 1)")
                                .foregroundStyle(.white.opacity(0.3))
                                .frame(width: gutter, alignment: .trailing)
                            Text(lines[index].isEmpty ? " " : lines[index])
                                .foregroundStyle(.white.opacity(0.88))
                                .fixedSize()
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .padding(.vertical, 1)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(index + 1 == highlight ? Color.orange.opacity(0.22) : .clear)
                        .id(index + 1)
                    }
                    if truncated {
                        Text("Preview cut off — open the file to see the rest.")
                            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                            .padding(10)
                    }
                }
                .padding(.vertical, 6)
                .textSelection(.enabled)
            }
            .onAppear {
                guard let highlight, highlight > 3 else { return }
                proxy.scrollTo(highlight, anchor: .center)
            }
        }
    }
}
