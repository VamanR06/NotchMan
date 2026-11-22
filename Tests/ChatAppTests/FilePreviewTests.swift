import Foundation
import Testing
@testable import ChatApp

@Suite struct FileMentionTests {
    /// The token around the first occurrence of `marker` in `line`.
    private func token(_ line: String, at marker: String) -> String? {
        let cells = Array(line)
        guard let range = line.range(of: marker) else { return nil }
        return FileMentions.token(in: cells, at: line.distance(from: line.startIndex, to: range.lowerBound))
    }

    @Test func picksThePathOutOfClaudeCodeOutput() {
        #expect(token("⏺ Update(Sources/App/Main.swift)", at: "App") == "Sources/App/Main.swift")
        #expect(token("⏺ Read(Package.swift)", at: "Pack") == "Package.swift")
        #expect(token("Plan saved to ~/.claude/plans/quiet-fox.md.", at: "plans") == "~/.claude/plans/quiet-fox.md")
        #expect(token("see `a.swift`, `b.swift`", at: "b.") == "b.swift")
        #expect(token("error at main.swift:42:7: oops", at: "main") == "main.swift:42:7")
        #expect(token("--config=build/app.json", at: "app") == "build/app.json")
        #expect(token("two  spaces", at: " ") == nil)
    }

    @Test func splitsLineNumbers() {
        #expect(FileMentions.split("a.swift:12").path == "a.swift")
        #expect(FileMentions.split("a.swift:12").line == 12)
        #expect(FileMentions.split("a.swift:12:4").line == 12)
        #expect(FileMentions.split("a.swift").line == nil)
    }

    @Test func resolvesAgainstTheTerminalsFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("src"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("src/a.swift")
        try "let a = 1\n".write(to: file, atomically: true, encoding: .utf8)

        let relative = FileMentions.resolve("src/a.swift:3", in: folder.path)
        #expect(relative?.url.path == file.standardizedFileURL.path)
        #expect(relative?.line == 3)
        #expect(FileMentions.resolve(file.path, in: nil)?.url.path == file.standardizedFileURL.path)
        #expect(FileMentions.resolve("file://" + file.path, in: nil) != nil)
        #expect(FileMentions.resolve("src", in: folder.path) != nil)                   // folders too
        #expect(FileMentions.resolve("src/missing.swift", in: folder.path) == nil)
        #expect(FileMentions.resolve("src/a.swift", in: nil) == nil)                    // nothing to resolve against
        #expect(FileMentions.resolve("https://example.com/src/a.swift", in: folder.path) == nil)
    }

    @Test func loadsMarkdownAsMarkdown() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        try "# Plan\n- step".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        guard case .markdown(let lines, false) = FilePreview.load(file) else {
            Issue.record("expected markdown")
            return
        }
        #expect(lines == ["# Plan", "- step"])
    }
}

@Suite struct MarkdownDocumentTests {
    @Test func parsesThePartsPlansUse() {
        let document = MarkdownDocument.parse("""
        # Plan


        ## Steps
        1. First
          - nested
        - [x] done
        > note
        ```swift
        # not a heading
        ```
        ---
        Plain **text**
        that wraps
        #hashtag
        """)
        #expect(document.blocks == [
            .heading(level: 1, text: "Plan"), .heading(level: 2, text: "Steps"),
            .list([.init(marker: "1.", text: "First", depth: 0), .init(marker: "•", text: "nested", depth: 1),
                   .init(marker: "☑", text: "done", depth: 0)]),
            .quote("note"), .code(language: "swift", text: "# not a heading"), .rule,
            .paragraph("Plain **text** that wraps #hashtag"),
        ])
    }

    @Test func readsTables() {
        let document = MarkdownDocument.parse("""
        Results:

        | Test | Before | After |
        |:-----|-------:|:-----:|
        | build | 41 s | **12 s** |
        | tests | 3 failing |
        | a \\| b | x | y |

        Done.
        """)
        #expect(document.blocks.count == 3)
        guard case .table(let header, let alignments, let rows) = document.blocks[1] else {
            Issue.record("expected a table: \(document.blocks)")
            return
        }
        #expect(header == ["Test", "Before", "After"])
        #expect(alignments == [.leading, .trailing, .center])
        #expect(rows == [["build", "41 s", "**12 s**"], ["tests", "3 failing", ""], ["a | b", "x", "y"]],
                "short rows are padded; an escaped pipe stays in its cell")
        #expect(document.blocks[2] == .paragraph("Done."))
    }

    @Test func aPipeInProseIsntATable() {
        #expect(MarkdownDocument.parse("Use a | b for or\nand more").blocks == [.paragraph("Use a | b for or and more")])
    }

    @Test func wrappedListItemsStayOneItem() {
        let document = MarkdownDocument.parse("- first item that\n  wraps here\n- second")
        #expect(document.blocks == [.list([.init(marker: "•", text: "first item that wraps here", depth: 0),
                                           .init(marker: "•", text: "second", depth: 0)])])
    }
}

/// Plain click previews, ⌘-click opens in the file's app; drags select and double-clicks pick words as before.
@MainActor @Suite struct PathClickTests {
    private func click(command: Bool = false, other: Bool = false, count: Int = 1, dragged: Bool = false,
                       mouse: Bool = false) -> NotchTerminalView.PathClick {
        NotchTerminalView.pathClick(command: command, otherModifiers: other, clickCount: count, dragged: dragged,
                                    programUsesMouse: mouse)
    }

    @Test func plainClickPreviews() { #expect(click() == .preview) }
    @Test func commandClickOpensInItsApp() { #expect(click(command: true) == .openInApp) }

    @Test func selectingAndWordPickingAreLeftAlone() {
        #expect(click(dragged: true) == .none)
        #expect(click(count: 2) == .none)
        #expect(click(other: true) == .none)
    }

    @Test func whenTheProgramUsesTheMouseCommandClickPreviews() {
        #expect(click(mouse: true) == .none)
        #expect(click(command: true, mouse: true) == .preview)
    }
}

/// What kind of preview each file gets.
@Suite struct PreviewContentTests {
    private func file(_ name: String, _ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + name)
        try data.write(to: url)
        return url
    }

    @Test func sourceIsShownAsText() throws {
        let url = try file("a.swift", Data("let x = 1\nprint(x)".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(FilePreview.load(url) == .text(["let x = 1", "print(x)"], truncated: false))
    }

    @Test func picturesAndDocumentsGoToQuickLook() throws {
        let png = try file("a.png", Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0]))
        let pdf = try file("a.pdf", Data("%PDF-1.4\n".utf8))
        defer { [png, pdf].forEach { try? FileManager.default.removeItem(at: $0) } }
        #expect(FilePreview.load(png) == .quickLook)
        #expect(FilePreview.load(pdf) == .quickLook)
    }

    @Test func otherBinaryFilesGoToQuickLook() throws {
        let url = try file("data.bin", Data([0, 1, 2, 3]))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(FilePreview.load(url) == .quickLook)
    }
}
