import AppKit
import SwiftUI

/// Keyboard selection in a notch list: ↑/↓ move, Return opens, ⌘Return runs the row's second action.
/// Apps keep one per list and call `handle` from `NotchApp.handleKey`.
@MainActor @Observable
public final class NotchListSelection {
    public var index: Int?

    public init() {}

    public func move(_ delta: Int, count: Int) {
        guard count > 0 else { index = nil; return }
        guard let index else { self.index = delta > 0 ? 0 : count - 1; return }
        self.index = min(max(index + delta, 0), count - 1)
    }

    public func isSelected(_ row: Int) -> Bool { index == row }

    /// Handles list keys; returns whether the key was used.
    public func handle(_ event: NSEvent, count: Int, open: (Int) -> Void, secondary: ((Int) -> Void)? = nil) -> Bool {
        switch event.keyCode {
        case 125: move(1, count: count); return true     // ↓
        case 126: move(-1, count: count); return true    // ↑
        case 36, 76:                                      // Return / Enter
            guard let index, index < count else { return false }
            if event.modifierFlags.contains(.command) { secondary?(index) } else { open(index) }
            return true
        default:
            return false
        }
    }
}

public extension View {
    /// Highlights the keyboard-selected row.
    func notchSelected(_ selected: Bool) -> some View {
        background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(selected ? 0.12 : 0)))
    }
}
