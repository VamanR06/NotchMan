import AppKit
import SwiftUI

/// A pluggable app hosted inside the notch.
///
/// Conforming types should be `@Observable` classes: the engine re-renders whenever
/// observed properties (such as `activity`) change. Apps stay alive while not
/// selected, so they can keep doing background work and update their activity.
@MainActor
public protocol NotchApp: AnyObject {
    /// Stable identifier, e.g. `"calendar"`. Used for storage and selection.
    var id: String { get }
    /// Display name shown in the dock tooltip and settings.
    var name: String { get }
    /// SF Symbol name for the dock icon.
    var iconSystemName: String { get }

    /// Height of the app's expanded content area (below the notch row).
    var expandedHeight: CGFloat { get }
    /// Width of the expanded notch while this app is selected.
    var expandedWidth: CGFloat { get }

    /// Optional compact indicator shown beside the notch while collapsed.
    var activity: NotchActivity? { get }
    /// Optional status mark on the app's dock icon.
    var dockBadge: NotchBadge? { get }

    /// Called once at launch. Start services, timers and observers here.
    func activate(context: NotchContext)
    /// Called at shutdown.
    func deactivate()

    /// Main content when the notch is expanded and this app is selected.
    func makeExpandedView() -> AnyView
    /// Optional settings pane shown in the NotchMan settings window.
    func makeSettingsView() -> AnyView?

    /// Files dragged to the notch open this app (the first one that accepts them) so it can take the drop.
    var acceptsFileDrags: Bool { get }

    /// Handles a message sent by another app via `NotchContext.send(_:to:)`.
    func receive(_ message: NotchMessage)

    /// A key pressed while the notch has the keyboard and no text field is typing. Return true if used
    /// (↑/↓/Return in lists, ⌘N for quick add, …).
    func handleKey(_ event: NSEvent) -> Bool
}

public extension NotchApp {
    var expandedHeight: CGFloat { 180 }
    var expandedWidth: CGFloat { 620 }
    var activity: NotchActivity? { nil }
    var dockBadge: NotchBadge? { nil }
    var acceptsFileDrags: Bool { false }
    func deactivate() {}
    func makeSettingsView() -> AnyView? { nil }
    func receive(_ message: NotchMessage) {}
    func handleKey(_ event: NSEvent) -> Bool { false }
}
