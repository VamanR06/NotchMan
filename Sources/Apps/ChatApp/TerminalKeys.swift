import SwiftUI

/// What a key press sends to a terminal program, as Claude Code's own terminal would send it. Nil for ⌘ shortcuts
/// (⌘V, ⌘C stay with the Mac) and keys with nothing to send.
enum TerminalKeys {
    static func bytes(for press: KeyPress) -> [UInt8]? {
        bytes(key: press.key, characters: press.characters, modifiers: press.modifiers)
    }

    static func bytes(key: KeyEquivalent, characters: String, modifiers: EventModifiers) -> [UInt8]? {
        if modifiers.contains(.command) { return nil }
        switch key {
        case .upArrow: return [0x1B, 0x5B, 0x41]
        case .downArrow: return [0x1B, 0x5B, 0x42]
        case .rightArrow: return [0x1B, 0x5B, 0x43]
        case .leftArrow: return [0x1B, 0x5B, 0x44]
        case .return: return [0x0D]
        case .escape: return [0x1B]
        case .tab: return modifiers.contains(.shift) ? [0x1B, 0x5B, 0x5A] : [0x09]
        case .delete: return [0x7F]
        case .deleteForward: return [0x1B, 0x5B, 0x33, 0x7E]
        case .home: return [0x1B, 0x5B, 0x48]
        case .end: return [0x1B, 0x5B, 0x46]
        case .pageUp: return [0x1B, 0x5B, 0x35, 0x7E]
        case .pageDown: return [0x1B, 0x5B, 0x36, 0x7E]
        default: break
        }
        // ⌃A … ⌃Z (Claude's menus use ⌃A, ⌃B; ⌃U clears a line).
        if modifiers.contains(.control), let letter = key.character.lowercased().first, letter.isLetter,
           let ascii = letter.asciiValue {
            return [ascii - 96]
        }
        guard !characters.isEmpty else { return nil }
        return Array(characters.utf8)
    }
}
