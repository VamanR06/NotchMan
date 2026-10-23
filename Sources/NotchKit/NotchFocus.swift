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
        // Remember the app to return to — but not a password helper (clicking back into the notch from AutoFill
        // shouldn't make AutoFill the app focus returns to), and keep the original if we already have one.
        if let front, front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
           !systemHelperBundleIDs.contains(front.bundleIdentifier ?? ""), previous == nil {
            previous = front
        }
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

    // MARK: - System password helpers

    /// macOS shows password AutoFill and its unlock prompt from separate helper processes. Their panels only take
    /// the keyboard while their own process is active, and clicking them doesn't activate it — so after you click
    /// back into the notch, typing would keep going to NotchMan.
    static let systemHelperBundleIDs: Set<String> = [
        "com.apple.AutoFillPanelService",
        "com.apple.LocalAuthentication.UIAgent",
        "com.apple.Passwords",
        "com.apple.SecurityAgent",
        "com.apple.coreautha",
    ]

    /// The app owning the frontmost window under `point` (Cocoa screen coordinates), other than NotchMan.
    /// Window owners and bounds are readable without Screen Recording permission.
    public static func otherAppWindowOwner(at point: CGPoint) -> NSRunningApplication? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let cgPoint = cgCoordinates(point)
        let me = ProcessInfo.processInfo.processIdentifier
        for window in list {  // front to back
            guard let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.contains(cgPoint),
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t else { continue }
            if pid == me { return nil }  // our own window is on top here
            return NSRunningApplication(processIdentifier: pid)
        }
        return nil
    }

    /// Cocoa (origin bottom-left of the main display) → Core Graphics window coordinates (origin top-left).
    static func cgCoordinates(_ point: CGPoint, mainDisplayHeight: CGFloat? = nil) -> CGPoint {
        let height = mainDisplayHeight ?? NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: point.x, y: height - point.y)
    }

    /// If the click at `point` landed on a system password helper's window, give that helper the keyboard and
    /// return true (the click wasn't "outside" — the notch should stay open).
    public static func handOffToSystemHelper(at point: CGPoint) -> Bool {
        guard let app = otherAppWindowOwner(at: point), let id = app.bundleIdentifier,
              systemHelperBundleIDs.contains(id) else { return false }
        log.notice("Handing keyboard to \(id, privacy: .public)")
        if NSApp.isActive { NSApp.yieldActivation(to: app) }
        app.activate()
        // Step back too: if NotchMan stays active, macOS keeps it in front of the helper.
        NSApp.deactivate()
        let target = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            MainActor.assumeIsolated {
                let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
                let ourKey = NSApp.keyWindow.map { String(describing: Swift.type(of: $0)) } ?? "none"
                log.notice("After hand-off to \(target, privacy: .public): front=\(front, privacy: .public) ourKeyWindow=\(ourKey, privacy: .public)")
            }
        }
        return true
    }

    /// Process ids that own on-screen windows, from the window list (front to back).
    static func onScreenWindowOwners() -> [pid_t] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        return list.compactMap { $0[kCGWindowOwnerPID as String] as? pid_t }
    }

    /// Password helpers with a window on screen, given the window owners and how to look up an app's bundle id.
    static func visibleHelpers(owners: [pid_t], bundleID: (pid_t) -> String?) -> [pid_t] {
        var seen = Set<pid_t>()
        return owners.filter { pid in
            guard seen.insert(pid).inserted, let id = bundleID(pid) else { return false }
            return systemHelperBundleIDs.contains(id)
        }
    }

    /// Clicking into the notch closes AutoFill / its unlock prompt, as clicking back into an app normally does:
    /// they belong to separate helpers NotchMan can't close, so hide those helpers (like ⌘H; macOS shows them
    /// again the next time AutoFill is used). Returns whether anything was hidden.
    @discardableResult
    public static func dismissSystemHelpers() -> Bool {
        let helpers = visibleHelpers(owners: onScreenWindowOwners()) {
            NSRunningApplication(processIdentifier: $0)?.bundleIdentifier
        }
        for pid in helpers {
            guard let app = NSRunningApplication(processIdentifier: pid) else { continue }
            log.notice("Closing \(app.bundleIdentifier ?? "?", privacy: .public) (clicked into the notch)")
            app.hide()
        }
        return !helpers.isEmpty
    }
}
