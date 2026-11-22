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

@Suite struct MarkdownLinesTests {
    @Test func parsesThePartsPlansUse() {
        let blocks = MarkdownLines.blocks([
            "# Plan", "", "", "## Steps", "1. First", "  - nested", "- [x] done", "> note", "```", "# not a heading", "```",
            "---", "Plain **text**", "#hashtag",
        ])
        #expect(blocks == [
            .heading(level: 1, text: "Plan"), .blank, .heading(level: 2, text: "Steps"),
            .bullet(marker: "1.", text: "First", indent: 0), .bullet(marker: "•", text: "nested", indent: 1),
            .bullet(marker: "☑", text: "done", indent: 0), .quote("note"), .code("# not a heading"), .rule,
            .paragraph("Plain **text**"), .paragraph("#hashtag"),
        ])
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
