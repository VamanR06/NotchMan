import AppKit
import Testing
@testable import ShelfApp

/// Click a shelved file to select it, ←/→ to move, Space to preview.
@MainActor @Suite struct ShelfSelectionTests {
    private func key(_ code: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                         characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
    }

    @Test func arrowsMoveTheSelectionWithinTheShelf() {
        let app = ShelfApp()
        let files = ["a.pdf", "b.png", "c.txt"].map { URL(fileURLWithPath: "/tmp/\($0)") }
        app.addToShelf(files)
        let shown = app.shownItems
        #expect(shown == files.reversed(), "newest first")
        #expect(app.handleKey(key(124)))  // → with nothing selected picks the first shown
        #expect(app.selected == shown[0])
        #expect(app.handleKey(key(124)) && app.handleKey(key(124)) && app.handleKey(key(124)))
        #expect(app.selected == shown[2])  // stops at the end
        #expect(app.handleKey(key(123)))
        #expect(app.selected == shown[1])
    }

    @Test func spaceNeedsASelectedFile() {
        let app = ShelfApp()
        app.addToShelf([URL(fileURLWithPath: "/tmp/a.pdf")])
        #expect(!app.handleKey(key(49)))  // nothing selected: Space is left alone
    }

    @Test func emptyShelfLeavesArrowsAlone() {
        #expect(!ShelfApp().handleKey(key(124)))
    }

    @Test func findFiltersTheShelfByName() {
        let app = ShelfApp()
        app.addToShelf(["Resume.pdf", "photo.png", "resume-old.docx"].map { URL(fileURLWithPath: "/tmp/\($0)") })
        app.query = "resume"
        #expect(app.shownItems.map(\.lastPathComponent) == ["resume-old.docx", "Resume.pdf"])
        app.query = ""
        #expect(app.shownItems.count == 3)
    }

    @Test func oldFilesComeOffTheShelf() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "shelf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "a.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let app = ShelfApp()
        app.addToShelf([file])
        app.pruneMissing(now: Date().addingTimeInterval(6 * 86400))
        #expect(app.items == [file], "kept for a week by default")
        app.pruneMissing(now: Date().addingTimeInterval(8 * 86400))
        #expect(app.items.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path), "the file itself stays")
    }

    @Test func neverMeansNever() throws {
        let app = ShelfApp()
        app.expiryDays = 0
        let file = URL(fileURLWithPath: "/tmp")
        app.addToShelf([file])
        app.pruneMissing(now: Date().addingTimeInterval(365 * 86400))
        #expect(app.items == [file])
    }
}
