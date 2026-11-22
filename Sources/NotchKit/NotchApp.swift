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

    /// The pointer started resting on the collapsed notch (it opens after the hover delay). A chance to look
    /// at what the user is doing, e.g. which page their browser shows.
    func notchWillOpen()
    /// When the notch opens by hover, the first app that claims it is shown instead of the last one used
    /// (e.g. Jobs while the browser shows a tracked job). Checked at opening and once shortly after.
    var claimsNotchOnOpen: Bool { get }

    /// Files dragged to the notch open this app (the first one that accepts them) so it can take the drop.
    var acceptsFileDrags: Bool { get }
    /// A drag of these files reached the notch and opened this app (before they're dropped anywhere).
    func fileDragEntered(_ urls: [URL])

    /// What the command bar can find and do in this app, given what's typed so far.
    func commands(for query: String) -> NotchCommands

    /// What this app has going on, in a line ("Standup starts in 3 min"), for choosing which app the notch opens to.
    var relevance: NotchRelevance? { get }

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
    func fileDragEntered(_ urls: [URL]) {}
    func commands(for query: String) -> NotchCommands { .none }
    var relevance: NotchRelevance? { nil }
    func notchWillOpen() {}
    var claimsNotchOnOpen: Bool { false }
    func deactivate() {}
    func makeSettingsView() -> AnyView? { nil }
    func receive(_ message: NotchMessage) {}
    func handleKey(_ event: NSEvent) -> Bool { false }
}

/// An app's current state for choosing what the notch opens to.
public struct NotchRelevance: Equatable, Sendable {
    /// One line, e.g. "1 permission request waiting (Bash)". Sent to Jev redacted.
    public var summary: String
    /// Worth opening to even without Jev: a meeting about to start, an approval waiting.
    public var isUrgent: Bool

    public init(_ summary: String, urgent: Bool = false) {
        self.summary = summary
        isUrgent = urgent
    }
}
