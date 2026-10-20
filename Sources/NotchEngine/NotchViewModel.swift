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

    // Layout constants.
    let expandedWidth: CGFloat = 620
    let activitySideWidth: CGFloat = 76
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

    var topActivity: NotchActivity? {
        apps.compactMap(\.activity).max { $0.priority < $1.priority }
    }

    var topCornerRadius: CGFloat { state == .expanded ? 14 : 6 }
    var bottomCornerRadius: CGFloat { state == .expanded ? 26 : 10 }

    /// Size of the black notch shape (including the flared top corners).
    var shapeSize: CGSize {
        let notch = geometry.notchSize
        switch state {
        case .collapsed:
            let sides = topActivity == nil ? 0 : activitySideWidth * 2
            return CGSize(width: notch.width + 2 * topCornerRadius + sides, height: notch.height)
        case .expanded:
            let content = selectedApp?.expandedHeight ?? 120
            return CGSize(width: expandedWidth, height: notch.height + content + expandedBottomPadding)
        }
    }

    /// Size the window must have to contain any state (plus room for the shadow).
    var windowSize: CGSize {
        let tallest = apps.map(\.expandedHeight).max() ?? 120
        return CGSize(width: expandedWidth + 60,
                      height: geometry.notchSize.height + tallest + expandedBottomPadding + 40)
    }

    /// The interactive region in global screen coordinates.
    var hitRect: CGRect {
        geometry.rect(hanging: shapeSize)
    }

    // MARK: - Mouse

    func mouseMoved(to point: CGPoint) {
        switch state {
        case .collapsed:
            // Slightly generous hover target so the notch is easy to hit.
            let hover = hitRect.insetBy(dx: -6, dy: -4)
            if hover.contains(point) {
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
            if hitRect.contains(point) {
                attentionExpansion = false
                pendingCollapse?.cancel()
                pendingCollapse = nil
            } else if !attentionExpansion, pendingCollapse == nil {
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
