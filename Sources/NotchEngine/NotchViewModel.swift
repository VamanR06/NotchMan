import SwiftUI
import NotchKit

@MainActor @Observable
final class NotchViewModel {
    enum State { case collapsed, expanded }

    private(set) var state: State = .collapsed
    var selectedAppID: String
    private(set) var pulsing = false
    var geometry: NotchGeometry

    let apps: [any NotchApp]

    /// While pinned, the expanded notch stays open when the mouse leaves.
    var isPinned = false
    /// A menu (context menu, ✨, …) is open; the mouse is on it, outside the notch, so don't collapse.
    @ObservationIgnored var isMenuOpen = false
    /// Apps asking to stay open while selected (`NotchContext.holdOpen`).
    @ObservationIgnored var heldApps: Set<String> = []

    private var isHeld: Bool { heldApps.contains(selectedAppID) }

    // Layout constants.
    /// Collapsed layout: width of one chip slot, of each side of a split (media) activity, and the margin
    /// kept clear of the shape's outer edge so content doesn't crowd the rounded corners.
    let chipSlotWidth: CGFloat = 66
    let splitSideWidth: CGFloat = 40
    let activityEdgeInset: CGFloat = 12
    /// Gap between neighbouring items on one side, so separate activities don't run together.
    let activitySpacing: CGFloat = 12
    /// At most this many activities show at once.
    let maxActivities = 3
    let expandedBottomPadding: CGFloat = 14

    @ObservationIgnored private var pendingCollapse: Task<Void, Never>?
    @ObservationIgnored private var pendingExpand: Task<Void, Never>?
    /// Set while an app-requested expansion is showing; cleared once the user hovers.
    @ObservationIgnored private var attentionExpansion = false

    init(apps: [any NotchApp], geometry: NotchGeometry) {
        self.apps = apps
        self.geometry = geometry
        self.selectedAppID = apps.first?.id ?? ""
    }

    var selectedApp: (any NotchApp)? {
        apps.first { $0.id == selectedAppID } ?? apps.first
    }

    /// An app's activity, keyed by the app so chip widths can be remembered.
    struct ActivityEntry {
        let id: String
        let activity: NotchActivity
        var priority: Int { activity.priority }
    }

    /// All published activities, highest priority first.
    private var activities: [ActivityEntry] {
        apps.compactMap { app in app.activity.map { ActivityEntry(id: app.id, activity: $0) } }
            .sorted { $0.priority > $1.priority }
    }

    /// Measured chip widths (chips size to their content); `chipSlotWidth` until measured.
    var chipWidths: [String: CGFloat] = [:]

    func chipWidth(_ id: String) -> CGFloat {
        min(chipWidths[id] ?? chipSlotWidth, maxChipWidth)
    }

    let maxChipWidth: CGFloat = 96

    /// What goes where beside the collapsed notch.
    struct CollapsedLayout {
        /// A split (media) activity on top: its leading/trailing hug the notch.
        var split: ActivityEntry?
        /// Chips on each side, nearest the notch first.
        var left: [ActivityEntry] = []
        var right: [ActivityEntry] = []
        var leftWidth: CGFloat = 0
        var rightWidth: CGFloat = 0
        var isEmpty: Bool { split == nil && left.isEmpty && right.isEmpty }
    }

    /// The top activity takes the split layout if it has one; the rest are chips filling the right side
    /// first, then the left, so a single chip extends the notch on one side only.
    var collapsedLayout: CollapsedLayout {
        var layout = CollapsedLayout()
        var rest = Array(activities.prefix(maxActivities))
        if let first = rest.first, first.activity.isSplit {
            layout.split = first
            rest.removeFirst()
        }
        for (index, activity) in rest.enumerated() {
            if index.isMultiple(of: 2) { layout.right.append(activity) } else { layout.left.append(activity) }
        }
        let split = layout.split != nil
        func width(_ chips: [ActivityEntry]) -> CGFloat {
            let items = chips.count + (split ? 1 : 0)
            guard items > 0 else { return 0 }
            return (split ? splitSideWidth : 0) + chips.map { chipWidth($0.id) }.reduce(0, +)
                + CGFloat(items - 1) * activitySpacing + activityEdgeInset
        }
        layout.leftWidth = width(layout.left)
        layout.rightWidth = width(layout.right)
        return layout
    }

    var topCornerRadius: CGFloat { state == .expanded ? 14 : 6 }
    var bottomCornerRadius: CGFloat { state == .expanded ? 26 : 10 }

    /// Size of the black notch shape (including the flared top corners).
    var shapeSize: CGSize {
        let notch = geometry.notchSize
        switch state {
        case .collapsed:
            let layout = collapsedLayout
            return CGSize(width: notch.width + 2 * topCornerRadius + layout.leftWidth + layout.rightWidth,
                          height: notch.height)
        case .expanded:
            return expandedSize
        }
    }

    /// Size of the shape when expanded with the selected app.
    var expandedSize: CGSize {
        let content = selectedApp?.expandedHeight ?? 120
        let width = selectedApp?.expandedWidth ?? 620
        return CGSize(width: width, height: geometry.notchSize.height + content + expandedBottomPadding)
    }

    /// Size the window must have to contain any state (plus room for the shadow).
    var windowSize: CGSize {
        let tallest = apps.map(\.expandedHeight).max() ?? 120
        let widest = apps.map(\.expandedWidth).max() ?? 620
        return CGSize(width: widest + 60,
                      height: geometry.notchSize.height + tallest + expandedBottomPadding + 40)
    }

    /// How far the shape's center sits right of the notch's center (the collapsed sides can differ).
    var shapeOffsetX: CGFloat {
        guard state == .collapsed else { return 0 }
        let layout = collapsedLayout
        return (layout.rightWidth - layout.leftWidth) / 2
    }

    /// The interactive region in global screen coordinates.
    var hitRect: CGRect {
        geometry.rect(hanging: shapeSize).offsetBy(dx: shapeOffsetX, dy: 0)
    }

    /// Whether `point` is over the notch. The rect is extended above the screen's top edge: a cursor
    /// pushed against the top (as it is under the physical notch) reports y == maxY, which
    /// `CGRect.contains` treats as outside.
    func contains(_ point: CGPoint, slack: CGFloat = 0) -> Bool {
        var rect = hitRect.insetBy(dx: -slack, dy: -slack)
        rect.size.height += 4
        return rect.contains(point)
    }

    // MARK: - Mouse

    /// How long the pointer must rest on the notch before it opens, so brushing past doesn't open it.
    static let hoverDelayKey = "hoverDelay"
    static let defaultHoverDelay: Double = 0.35

    static var hoverDelay: Double {
        let stored = UserDefaults.standard.object(forKey: hoverDelayKey) as? Double ?? defaultHoverDelay
        return min(max(stored, 0.05), 2)
    }

    func mouseMoved(to point: CGPoint) {
        switch state {
        case .collapsed:
            // Slightly generous hover target so the notch is easy to hit.
            if contains(point, slack: 4) {
                guard pendingExpand == nil else { return }
                pendingExpand = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(Self.hoverDelay))
                    guard !Task.isCancelled else { return }
                    self?.pendingExpand = nil
                    self?.expand()
                }
            } else {
                pendingExpand?.cancel()
                pendingExpand = nil
            }
        case .expanded:
            // Same slack as the collapsed hover target, so the two states can't fight over the edge.
            if contains(point, slack: 4) {
                attentionExpansion = false
                pendingCollapse?.cancel()
                pendingCollapse = nil
            } else if !attentionExpansion, !isPinned, !isMenuOpen, !isHeld, pendingCollapse == nil {
                scheduleCollapse(after: .milliseconds(250))
            }
        }
    }

    /// A click outside the notch (seen by the global monitor) closes a held notch; pinned ones stay.
    func clickedOutside(at point: CGPoint) {
        guard state == .expanded, isHeld, !isPinned, !contains(point, slack: 4) else { return }
        collapse()
    }

    func expand() {
        pendingCollapse?.cancel()
        pendingCollapse = nil
        withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) { state = .expanded }
    }

    func collapse() {
        attentionExpansion = false
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { state = .collapsed }
    }

    private func scheduleCollapse(after delay: Duration) {
        pendingCollapse?.cancel()
        pendingCollapse = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.pendingCollapse = nil
            self?.collapse()
        }
    }

    func select(_ appID: String) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { selectedAppID = appID }
    }

    // MARK: - Attention

    func handleAttention(_ attention: NotchAttention, from appID: String) {
        switch attention {
        case .pulse:
            withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) { pulsing = true }
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { self?.pulsing = false }
            }
        case .expand(let duration):
            select(appID)
            guard state == .collapsed else { return }
            attentionExpansion = true
            expand()
            pendingCollapse = Task { [weak self] in
                try? await Task.sleep(for: .seconds(duration))
                guard !Task.isCancelled, let self, self.attentionExpansion else { return }
                self.pendingCollapse = nil
                self.collapse()
            }
        }
    }
}
