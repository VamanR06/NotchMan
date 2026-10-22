import AppKit

/// Keyboard focus for content in the notch.
///
/// The notch panel never makes NotchMan the active app, which is right for clicks and hovering but wrong for
/// pop-ups that content opens — e.g. a web page's password AutoFill list is its own window and can only take the
/// keyboard if NotchMan is active. So typing into web content activates NotchMan, and when the notch closes,
/// focus goes back to the app you were in.
@MainActor
public enum NotchFocus {
    private static var previous: NSRunningApplication?

    /// Call when the user clicks into content that may open pop-ups needing the keyboard.
    public static func activateForTyping() {
        guard !NSApp.isActive else { return }
        let front = NSWorkspace.shared.frontmostApplication
        previous = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        NSApp.activate()
    }

    /// Called when the notch closes: return focus to the app the user was in — unless one of NotchMan's regular
    /// windows (Settings, a popped-out chat) is in front and should keep it.
    public static func restore() {
        guard let previous else { return }
        self.previous = nil
        guard NSApp.isActive else { return }
        if let key = NSApp.keyWindow, key.isVisible, key.styleMask.contains(.titled) { return }
        NSApp.yieldActivation(to: previous)
        previous.activate()
    }
}
