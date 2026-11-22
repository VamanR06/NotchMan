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
        #expect(app.handleKey(key(124)))  // → with nothing selected picks the first
        #expect(app.selected == files[0])
        #expect(app.handleKey(key(124)) && app.handleKey(key(124)) && app.handleKey(key(124)))
        #expect(app.selected == files[2])  // stops at the end
        #expect(app.handleKey(key(123)))
        #expect(app.selected == files[1])
    }

    @Test func spaceNeedsASelectedFile() {
        let app = ShelfApp()
        app.addToShelf([URL(fileURLWithPath: "/tmp/a.pdf")])
        #expect(!app.handleKey(key(49)))  // nothing selected: Space is left alone
    }

    @Test func emptyShelfLeavesArrowsAlone() {
        #expect(!ShelfApp().handleKey(key(124)))
    }
}
