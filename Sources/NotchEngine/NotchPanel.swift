import AppKit
import SwiftUI

/// Borderless, non-activating panel that floats above the menu bar.
final class NotchPanel: NSPanel {
    /// Above the menu bar, so the notch can grow out of it.
    static let windowLevel: NSWindow.Level = .statusBar + 1
    /// For dialogs opened from the notch (file pickers, alerts), which would otherwise sit under it.
    static let aboveNotch: NSWindow.Level = windowLevel + 1

    init(contentRect: CGRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = Self.windowLevel
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Allow the panel to sit over the menu bar / notch area.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Hosting view that reacts to the first click even when the panel isn't key.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
