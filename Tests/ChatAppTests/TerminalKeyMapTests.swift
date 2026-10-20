import AppKit
import Testing
@testable import ChatApp

@Suite struct TerminalKeyMapTests {
    private typealias K = TerminalKeyMap.KeyCode

    private func action(_ code: UInt16, _ mods: NSEvent.ModifierFlags, chars: String? = nil, kitty: Bool = false)
        -> TerminalKeyMap.Action? {
        TerminalKeyMap.action(keyCode: code, characters: chars, modifiers: mods, kittyKeyboard: kitty)
    }

    @Test func macShortcutsBecomeTerminalInput() {
        #expect(action(K.returnKey, .shift) == .send([0x1B, 0x0D]))       // ⇧↩ newline
        #expect(action(K.keypadEnter, .shift) == .send([0x1B, 0x0D]))
        #expect(action(K.delete, .command) == .send([0x15]))              // ⌘⌫
        #expect(action(K.delete, .option) == .send([0x1B, 0x7F]))         // ⌥⌫
        #expect(action(K.forwardDelete, .command) == .send([0x0B]))       // ⌘⌦
        #expect(action(K.left, .command) == .send([0x01]))                // ⌘←
        #expect(action(K.right, .command) == .send([0x05]))               // ⌘→
        #expect(action(K.left, .option) == .send([0x1B, 0x62]))           // ⌥←
        #expect(action(K.right, .option) == .send([0x1B, 0x66]))          // ⌥→
        #expect(action(40, .command, chars: "k") == .clear)               // ⌘K
    }

    @Test func plainKeysAndOtherShortcutsAreLeftAlone() {
        #expect(action(K.returnKey, []) == nil)                           // ↩ still submits
        #expect(action(K.delete, []) == nil)
        #expect(action(8, .command, chars: "c") == nil)                   // ⌘C stays copy
        #expect(action(9, .command, chars: "v") == nil)                   // ⌘V stays paste
        #expect(action(K.left, [.command, .shift]) == nil)                // selection combos untouched
        // Device-dependent flags (e.g. numeric pad, caps lock) don't affect matching.
        #expect(action(K.left, [.command, .numericPad, .function]) == .send([0x01]))
    }

    @Test func kittyKeyboardKeepsItsOwnShiftEnter() {
        #expect(action(K.returnKey, .shift, kitty: true) == nil)
        #expect(action(K.delete, .command, kitty: true) == .send([0x15]))
    }

    @MainActor @Test func shortcutsReachTheProgramAsBytes() async throws {
        let agent = ClaudeAgent(id: "s", shortID: "s", name: "t", cwd: "/tmp", kind: .background,
                                state: nil, status: nil, startedAt: nil)
        let terminal = AgentTerminal(agent: agent)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 680, height: 380), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = terminal.view
        // Raw mode so bytes arrive untranslated; print the first 6 as hex.
        terminal.run("stty raw -echo; head -c 6 | xxd -p")
        try await Task.sleep(for: .milliseconds(700))

        func key(_ code: UInt16, _ mods: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0,
                             windowNumber: window.windowNumber, context: nil, characters: "",
                             charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
        }
        #expect(terminal.view.handle(key(36, .shift)))       // ⇧↩  → 1b 0d
        #expect(terminal.view.handle(key(51, .command)))     // ⌘⌫  → 15
        #expect(terminal.view.handle(key(123, .option)))     // ⌥←  → 1b 62
        #expect(terminal.view.handle(key(123, .command)))    // ⌘←  → 01
        for _ in 0..<30 where terminal.isRunning { try await Task.sleep(for: .milliseconds(100)) }
        #expect(terminal.screenText.contains("1b0d151b6201"), "got: \(terminal.screenText)")
        _ = window
    }
}
