import SwiftUI

/// Compact live content shown on either side of the notch while collapsed,
/// e.g. album art + a playing indicator, or "Standup in 5m".
///
/// The highest-`priority` activity gets both sides of the notch. Up to two more appear beside it as
/// their `compact` view (an icon-sized mark); activities without one are only shown when they're on top.
public struct NotchActivity {
    public var leading: AnyView?
    public var trailing: AnyView?
    /// Icon-sized (about 20pt) version shown when another app's activity is on top.
    public var compact: AnyView?
    public var priority: Int

    public init<L: View, T: View>(
        priority: Int = 0,
        @ViewBuilder leading: () -> L,
        @ViewBuilder trailing: () -> T
    ) {
        self.priority = priority
        self.leading = AnyView(leading())
        self.trailing = AnyView(trailing())
    }

    public init<L: View, T: View, C: View>(
        priority: Int = 0,
        @ViewBuilder leading: () -> L,
        @ViewBuilder trailing: () -> T,
        @ViewBuilder compact: () -> C
    ) {
        self.init(priority: priority, leading: leading, trailing: trailing)
        self.compact = AnyView(compact())
    }
}

/// A small status mark on an app's dock icon.
public enum NotchBadge: Equatable {
    /// Something is in progress (pulsing dot).
    case busy
    /// Something is waiting to be seen.
    case dot(Color)
}

/// Ways an app can ask for the user's attention.
public enum NotchAttention: Sendable {
    /// Briefly pulse the collapsed notch.
    case pulse
    /// Expand the notch with this app selected; auto-collapses unless hovered.
    case expand(duration: TimeInterval = 4)
}
