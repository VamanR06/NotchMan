import AppKit
import SwiftUI
import Testing
@testable import NotchKit

/// Drives real SwiftUI text fields in a window, the way NotchMan's panels host them.
@MainActor @Suite(.serialized) struct TextShortcutsTests {
    private struct Field: View {
        @Binding var text: String
        let multiLine: Bool
        let onSubmit: () -> Void
        @FocusState private var focused: Bool

        var body: some View {
            Group {
                if multiLine {
                    TextField("x", text: $text, axis: .vertical)
                } else {
                    TextField("x", text: $text)
                }
            }
            .focused($focused)
            .onSubmit(onSubmit)
            .onAppear { focused = true }
        }
    }

    private final class Box { var text: String; var submits = 0; init(_ t: String) { text = t } }

    private func makeWindow(_ box: Box, multiLine: Bool) async throws -> NSWindow {
        let binding = Binding(get: { box.text }, set: { box.text = $0 })
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 120), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Field(text: binding, multiLine: multiLine) { box.submits += 1 })
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<20 where !(window.firstResponder is NSTextView) { try await Task.sleep(for: .milliseconds(50)) }
        // Cursor at the end.
        (window.firstResponder as? NSTextView)?.moveToEndOfDocument(nil)
        return window
    }

    private func key(_ window: NSWindow, _ code: UInt16, _ mods: NSEvent.ModifierFlags, _ chars: String = "") -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0,
                         windowNumber: window.windowNumber, context: nil, characters: chars,
                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    /// Like the app: give our shortcuts first look, then deliver normally.
    private func press(_ window: NSWindow, _ event: NSEvent) {
        if !TextShortcuts.handle(event) { window.sendEvent(event) }
    }

    @Test func shiftReturnAddsALineInMultiLineFields() async throws {
        let box = Box("first")
        let window = try await makeWindow(box, multiLine: true)
        press(window, key(window, 36, .shift, "\r"))
        #expect(box.text == "first\n")
        #expect(box.submits == 0)
        press(window, key(window, 36, [], "\r"))
        #expect(box.submits == 1, "plain Return still submits")
        window.close()
    }

    @Test func singleLineFieldsKeepShiftReturnAsReturn() async throws {
        let box = Box("search")
        let window = try await makeWindow(box, multiLine: false)
        press(window, key(window, 36, .shift, "\r"))
        #expect(box.text == "search")
        #expect(box.submits == 1)
        window.close()
    }

    @Test func standardMacEditingShortcutsWork() async throws {
        let box = Box("hello big world")
        let window = try await makeWindow(box, multiLine: true)
        press(window, key(window, 51, .option, "\u{7f}"))   // ⌥⌫ deletes "world"
        #expect(box.text == "hello big ")
        press(window, key(window, 51, .command, "\u{7f}"))  // ⌘⌫ deletes to line start
        #expect(box.text == "")
        window.close()
    }
}
