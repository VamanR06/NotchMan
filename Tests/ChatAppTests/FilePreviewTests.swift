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

@Suite struct FilePreviewLayoutTests {
    private let container = CGSize(width: 700, height: 400)
    private let card = CGSize(width: 480, height: 290)

    @Test func goesBelowTheClickedRowWhenItFits() {
        let origin = FilePreviewLayout.origin(card: card, anchor: CGRect(x: 100, y: 30, width: 1, height: 15), in: container)
        #expect(origin == CGPoint(x: 8, y: 49))
    }

    @Test func goesAboveNearTheBottom() {
        let origin = FilePreviewLayout.origin(card: card, anchor: CGRect(x: 650, y: 360, width: 1, height: 15), in: container)
        #expect(origin == CGPoint(x: 212, y: 66))
    }

    @Test func centersWhenNeitherFits() {
        let origin = FilePreviewLayout.origin(card: card, anchor: CGRect(x: 350, y: 150, width: 0, height: 15), in: container)
        #expect(origin == CGPoint(x: 110, y: 55))
    }
}
