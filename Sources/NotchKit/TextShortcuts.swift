import AppKit

/// Keyboard behavior shared by every text field in NotchMan.
///
/// macOS text fields already handle ⌘⌫, ⌥⌫, ⌘←/→, ⌥←/→ and friends. The gap is ⇧↩: a text field treats it as
/// Return (submit). In multi-line fields we make it insert a line break instead, like chat apps and the
/// terminal. Single-line fields (search, settings) are left alone.
@MainActor
public enum TextShortcuts {
    /// Handles `event` if it's one of our shortcuts for the focused text. Returns true if it was consumed.
    public static func handle(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.keyCode == 36 || event.keyCode == 76,  // Return / keypad Enter
              event.modifierFlags.intersection([.shift, .command, .option, .control]) == .shift,
              let editor = event.window?.firstResponder as? NSTextView,
              editor.isFieldEditor,
              let field = editor.delegate as? NSTextField,
              isMultiLine(field) else { return false }
        editor.insertNewlineIgnoringFieldEditor(nil)
        return true
    }

    /// SwiftUI reports `usesSingleLineMode == false` for both kinds; what differs is that a multi-line
    /// (`axis: .vertical`) field wraps its text while a single-line one scrolls horizontally.
    static func isMultiLine(_ field: NSTextField) -> Bool {
        guard field.isEditable, !field.usesSingleLineMode, field.maximumNumberOfLines != 1, let cell = field.cell else {
            return false
        }
        return cell.wraps && !cell.isScrollable
    }
}
