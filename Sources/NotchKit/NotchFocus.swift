import AppKit
import os

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

    // MARK: - Pop-ups that need the keyboard

    nonisolated private static let log = Logger(subsystem: "com.notchman", category: "focus")
    private static var observers: [NSObjectProtocol] = []

    /// Watches for pop-up windows (AutoFill, its unlock prompt) and gives them the keyboard when they appear,
    /// and logs window/app changes while a pop-up flow is underway, to diagnose focus problems.
    public static func startWatchingPopups(isNotchWindow: @escaping @MainActor (NSWindow) -> Bool) {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil,
                                            queue: .main) { note in
            // Delivered on the main queue.
            nonisolated(unsafe) let object = note.object
            MainActor.assumeIsolated {
                guard let window = object as? NSWindow, window.isVisible,
                      window.occlusionState.contains(.visible), !isNotchWindow(window) else { return }
                let type = String(describing: Swift.type(of: window))
                log.notice("""
                    Window shown: \(type, privacy: .public) titled=\(window.styleMask.contains(.titled), privacy: .public) \
                    canBecomeKey=\(window.canBecomeKey, privacy: .public) key=\(window.isKeyWindow, privacy: .public) \
                    appActive=\(NSApp.isActive, privacy: .public)
                    """)
                // A pop-up from notch content that accepts typing gets the keyboard.
                if !window.styleMask.contains(.titled), window.canBecomeKey, !window.isKeyWindow {
                    if !NSApp.isActive { activateForTyping() }
                    window.makeKeyAndOrderFront(nil)
                }
            }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let id = app?.bundleIdentifier ?? "?"
            log.notice("App activated: \(id, privacy: .public)")
        })
    }
}
