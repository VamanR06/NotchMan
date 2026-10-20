import SwiftUI

/// Live status shown beside the collapsed notch.
///
/// Every activity has a `chip`: one self-contained mark, icon and label together (see `NotchChip`), e.g.
/// "☑ 2 late" or "⟳ GPT". The notch shows up to three, highest `priority` first, filling the right side and
/// then the left. Media can also offer a split presentation (`leading`/`trailing` hugging the notch, like
/// artwork on one side and a playing indicator on the other), used when it's the top activity.
public struct NotchActivity {
    public var priority: Int
    public var chip: AnyView
    public var leading: AnyView?
    public var trailing: AnyView?

    /// Uses the split presentation when on top.
    public var isSplit: Bool { leading != nil || trailing != nil }

    public init<C: View>(priority: Int = 0, @ViewBuilder chip: () -> C) {
        self.priority = priority
        self.chip = AnyView(chip())
    }

    public init<L: View, T: View, C: View>(
        priority: Int = 0,
        @ViewBuilder leading: () -> L,
        @ViewBuilder trailing: () -> T,
        @ViewBuilder chip: () -> C
    ) {
        self.priority = priority
        self.chip = AnyView(chip())
        self.leading = AnyView(leading())
        self.trailing = AnyView(trailing())
    }
}

/// The standard notch chip: a small icon next to a short label ("2 late", "5m", "GPT").
public struct NotchChip<Icon: View>: View {
    private let text: String
    private let tint: Color
    private let icon: Icon

    public init(_ text: String, tint: Color = .white, @ViewBuilder icon: () -> Icon) {
        self.text = text
        self.tint = tint
        self.icon = icon()
    }

    public var body: some View {
        HStack(spacing: 4) {
            icon.frame(height: 12)
            Text(text)
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }
}

public extension NotchChip where Icon == AnyView {
    /// Chip with an SF Symbol icon in the same tint as the label.
    init(_ text: String, systemImage: String, tint: Color = .white) {
        self.init(text, tint: tint) {
            AnyView(Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint))
        }
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
