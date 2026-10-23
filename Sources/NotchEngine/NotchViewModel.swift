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

    /// Opened because files are being dragged to it: stays open until the drag ends.
    @ObservationIgnored var dragHeld = false

    /// Opened with the global hotkey: stays open (on any app) until Esc, the hotkey again, or a click outside.
    @ObservationIgnored var keyboardHeld = false

    private var isHeld: Bool { keyboardHeld || dragHeld || heldApps.contains(selectedAppID) }

    /// The user is pointing at the notch, so it should take the keyboard (⌘1–9, arrows, Esc) from the app
    /// they were in. Called once per opening; never for openings the user didn't ask for (meeting heads-up).
    @ObservationIgnored var onWantsKeyboard: (() -> Void)?
    /// The notch closed; give the keyboard back.
    @ObservationIgnored var onCollapse: (() -> Void)?
    @ObservationIgnored private var tookKeyboard = false
    /// After switching apps the shape can shrink out from under the cursor. While the cursor is still where
    /// the previous (larger) shape was, that doesn't count as leaving.
    @ObservationIgnored private var selectionGraceRect: CGRect?

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

    /// A short-lived status (HUD) shown in place of the chips while collapsed.
    private(set) var transient: NotchTransient?
    @ObservationIgnored private var transientExpiry: Task<Void, Never>?
    /// Width of each side of the collapsed notch while a transient shows.
    let transientSideWidth: CGFloat = 72

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
            if transient != nil {
                return CGSize(width: notch.width + 2 * topCornerRadius + 2 * transientSideWidth, height: notch.height)
            }
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
        guard state == .collapsed, transient == nil else { return 0 }
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
        Self.contains(hitRect, point, slack: slack)
    }

    static func contains(_ hitRect: CGRect, _ point: CGPoint, slack: CGFloat) -> Bool {
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
                    self?.takeKeyboard()
                }
            } else {
                pendingExpand?.cancel()
                pendingExpand = nil
            }
        case .expanded:
            // Same slack as the collapsed hover target, so the two states can't fight over the edge.
            if contains(point, slack: 4) {
                attentionExpansion = false
                selectionGraceRect = nil
                pendingCollapse?.cancel()
                pendingCollapse = nil
                takeKeyboard()
            } else if let grace = selectionGraceRect, Self.contains(grace, point, slack: 4) {
                // Still inside where the notch was before switching apps.
                pendingCollapse?.cancel()
                pendingCollapse = nil
            } else if !attentionExpansion, !isPinned, !isMenuOpen, !isHeld, pendingCollapse == nil {
                selectionGraceRect = nil
                scheduleCollapse(after: .milliseconds(250))
            }
        }
    }

    /// A click outside the notch (seen by the global monitor) closes a held notch; pinned ones stay.
    func clickedOutside(at point: CGPoint) {
        guard state == .expanded, isHeld, !isPinned, !contains(point, slack: 4) else { return }
        collapse()
    }

    private func takeKeyboard() {
        guard state == .expanded, !tookKeyboard else { return }
        tookKeyboard = true
        onWantsKeyboard?()
    }

    func expand() {
        pendingCollapse?.cancel()
        pendingCollapse = nil
        withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) { state = .expanded }
    }

    func collapse() {
        attentionExpansion = false
        // Holds last for one opening: the next time, moving away closes the notch again until re-held.
        heldApps.removeAll()
        keyboardHeld = false
        dragHeld = false
        selectionGraceRect = nil
        let hadKeyboard = tookKeyboard
        tookKeyboard = false
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { state = .collapsed }
        if hadKeyboard { onCollapse?() }
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
        if state == .expanded, appID != selectedAppID {
            // Remember the larger of the old shape and any earlier grace area, so quick switches chain.
            selectionGraceRect = selectionGraceRect.map { $0.union(hitRect) } ?? hitRect
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { selectedAppID = appID }
    }

    // MARK: - Transients

    /// Shows `transient` until its duration passes; a newer one replaces it and restarts the timer.
    func show(_ transient: NotchTransient) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { self.transient = transient }
        transientExpiry?.cancel()
        transientExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(transient.duration))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { self?.transient = nil }
        }
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
