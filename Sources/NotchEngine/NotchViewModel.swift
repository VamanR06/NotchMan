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

    // Layout constants.
    let activitySideWidth: CGFloat = 84
    let activityEdgeInset: CGFloat = 14
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

    /// All published activities, highest priority first.
    private var activities: [NotchActivity] {
        apps.compactMap(\.activity).sorted { $0.priority > $1.priority }
    }

    var topActivity: NotchActivity? {
        activities.first
    }

    /// Up to two runner-up activities, shown as compact icons beside the top one.
    var extraActivities: [NotchActivity] {
        Array(activities.dropFirst().filter { $0.compact != nil }.prefix(2))
    }

    /// Width of one compact slot.
    let extraSlotWidth: CGFloat = 26

    /// Each side grows by the same amount so the shape stays centered on the notch.
    var collapsedSideWidth: CGFloat {
        activitySideWidth + CGFloat((extraActivities.count + 1) / 2) * extraSlotWidth
    }

    var topCornerRadius: CGFloat { state == .expanded ? 14 : 6 }
    var bottomCornerRadius: CGFloat { state == .expanded ? 26 : 10 }

    /// Size of the black notch shape (including the flared top corners).
    var shapeSize: CGSize {
        let notch = geometry.notchSize
        switch state {
        case .collapsed:
            let sides = topActivity == nil ? 0 : collapsedSideWidth * 2
            return CGSize(width: notch.width + 2 * topCornerRadius + sides, height: notch.height)
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

    /// The interactive region in global screen coordinates.
    var hitRect: CGRect {
        geometry.rect(hanging: shapeSize)
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

    func mouseMoved(to point: CGPoint) {
        switch state {
        case .collapsed:
            // Slightly generous hover target so the notch is easy to hit.
            if contains(point, slack: 4) {
                guard pendingExpand == nil else { return }
                pendingExpand = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(120))
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
            } else if !attentionExpansion, !isPinned, pendingCollapse == nil {
                scheduleCollapse(after: .milliseconds(250))
            }
        }
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
