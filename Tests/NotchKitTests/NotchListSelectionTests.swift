import AppKit
import Testing
@testable import NotchKit

@MainActor @Suite struct NotchListSelectionTests {
    private func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                         context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
    }

    @Test func arrowsStartAtTheEndTheyPointTo() {
        let down = NotchListSelection()
        down.move(1, count: 3)
        #expect(down.index == 0)
        let up = NotchListSelection()
        up.move(-1, count: 3)
        #expect(up.index == 2)
    }

    @Test func movesStayInBounds() {
        let selection = NotchListSelection()
        selection.index = 2
        selection.move(1, count: 3)
        #expect(selection.index == 2)
        selection.move(-5, count: 3)
        #expect(selection.index == 0)
        selection.move(1, count: 0)
        #expect(selection.index == nil)
    }

    @Test func returnOpensAndCommandReturnRunsSecondary() {
        let selection = NotchListSelection()
        var opened: [Int] = [], secondary: [Int] = []
        // Nothing selected yet: Return isn't used.
        #expect(!selection.handle(key(36), count: 2, open: { opened.append($0) }))
        #expect(selection.handle(key(125), count: 2, open: { opened.append($0) }))
        #expect(selection.handle(key(36), count: 2, open: { opened.append($0) }, secondary: { secondary.append($0) }))
        #expect(selection.handle(key(36, .command), count: 2, open: { opened.append($0) }, secondary: { secondary.append($0) }))
        #expect(opened == [0] && secondary == [0])
        // Other keys pass through.
        #expect(!selection.handle(key(0), count: 2, open: { _ in }))
    }
}
