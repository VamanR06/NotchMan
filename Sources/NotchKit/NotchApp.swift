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

    /// Called once at launch. Start services, timers and observers here.
    func activate(context: NotchContext)
    /// Called at shutdown.
    func deactivate()

    /// Main content when the notch is expanded and this app is selected.
    func makeExpandedView() -> AnyView
    /// Optional settings pane shown in the NotchMan settings window.
    func makeSettingsView() -> AnyView?

    /// Handles a message sent by another app via `NotchContext.send(_:to:)`.
    func receive(_ message: NotchMessage)
}

public extension NotchApp {
    var expandedHeight: CGFloat { 180 }
    var expandedWidth: CGFloat { 620 }
    var activity: NotchActivity? { nil }
    func deactivate() {}
    func makeSettingsView() -> AnyView? { nil }
    func receive(_ message: NotchMessage) {}
}
