@testable import ChatApp
import SwiftUI
import Testing

/// Keys typed while one of Claude's menus is open, as its terminal would get them.
@MainActor @Suite struct TerminalKeysTests {
    private func bytes(_ key: KeyEquivalent, _ characters: String = "", _ modifiers: EventModifiers = []) -> [UInt8]? {
        TerminalKeys.bytes(key: key, characters: characters, modifiers: modifiers)
    }

    @Test func navigationKeys() {
        #expect(bytes(.upArrow) == [0x1B, 0x5B, 0x41])
        #expect(bytes(.downArrow) == [0x1B, 0x5B, 0x42])
        #expect(bytes(.leftArrow) == [0x1B, 0x5B, 0x44])
        #expect(bytes(.rightArrow) == [0x1B, 0x5B, 0x43])
        #expect(bytes(.return) == [0x0D])
        #expect(bytes(.escape) == [0x1B])
        #expect(bytes(.tab) == [0x09])
        #expect(bytes(.tab, "", .shift) == [0x1B, 0x5B, 0x5A])
        #expect(bytes(.delete) == [0x7F])
    }

    @Test func lettersAndControlKeys() {
        #expect(bytes(KeyEquivalent("s"), "s") == Array("s".utf8), "a hint's key, like s to use this session only")
        #expect(bytes(KeyEquivalent("/"), "/") == Array("/".utf8), "/ to search")
        #expect(bytes(KeyEquivalent("a"), "\u{1}", .control) == [0x01], "Ctrl+A to show all projects")
        #expect(bytes(KeyEquivalent("v"), "v", .command) == nil, "⌘ shortcuts stay with the Mac")
    }

    @Test func moreModelsIsAnOptionToo() throws {
        let screen = [
            String(repeating: "▔", count: 60),
            "  Select model",
            "    1.  Default (recommended)  Opus 5.5 · Best for everyday, complex tasks",
            "    2.  Opus 5.5               For complex work and everyday tasks",
            "  ❯ 5.  Haiku 5.5 ✔            Fastest for quick answers",
            "    ▸   More models",
            "",
            "  ◐ Medium effort (default) ←/→ to adjust",
            "",
            "  Use /fast to turn on fast mode (Opus 5.5).",
            "  s to use this session only · Enter to save · Esc to cancel",
        ]
        let prompt = try #require(ClaudePrompt.parse(screen))
        #expect(prompt.options.map(\.label) == ["Default (recommended)  Opus 5.5 · Best for everyday, complex tasks",
                                                "Opus 5.5               For complex work and everyday tasks",
                                                "Haiku 5.5 ✔            Fastest for quick answers", "More models"])
        let more = try #require(prompt.options.last)
        #expect(more.number == nil)
        #expect(prompt.keys(for: more) == [0x1B, 0x5B, 0x42, 0x0D], "one down from Haiku, then Return")
    }
}
