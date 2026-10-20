import SwiftUI

/// Compact live content shown on either side of the notch while collapsed,
/// e.g. album art + a playing indicator, or "Standup in 5m".
///
/// When several apps publish an activity, the one with the highest `priority` wins.
public struct NotchActivity {
    public var leading: AnyView?
    public var trailing: AnyView?
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
}

/// Ways an app can ask for the user's attention.
public enum NotchAttention: Sendable {
    /// Briefly pulse the collapsed notch.
    case pulse
    /// Expand the notch with this app selected; auto-collapses unless hovered.
    case expand(duration: TimeInterval = 4)
}
