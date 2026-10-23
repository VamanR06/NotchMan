import AppKit
import SwiftUI
import Testing
import NotchKit
@testable import NotchEngine

@MainActor @Observable
private final class SizedApp: NotchApp {
    let id: String
    let name: String
    let iconSystemName = "circle"
    let expandedWidth: CGFloat

    init(_ id: String, width: CGFloat) {
        self.id = id
        self.name = id
        self.expandedWidth = width
    }

    func activate(context: NotchContext) {}
    func makeExpandedView() -> AnyView { AnyView(EmptyView()) }
}

@MainActor @Suite(.serialized) struct FocusAndSwitchingTests {
    private let geometry = NotchGeometry(
        screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        notchSize: CGSize(width: 185, height: 32), centerX: 756, hasNotch: true)

    private func model() -> NotchViewModel {
        NotchViewModel(apps: [SizedApp("agents", width: 720), SizedApp("music", width: 480)], geometry: geometry)
    }

    @Test func switchingToANarrowerAppDoesNotCloseUnderTheCursor() async throws {
        let model = model()
        model.expand()
        // Near the left edge of the wide (Agents) shape: outside the narrow one.
        let wide = model.hitRect
        let point = CGPoint(x: wide.minX + 20, y: wide.midY)
        model.mouseMoved(to: point)
        model.select("music")
        #expect(!model.contains(point, slack: 4))
        model.mouseMoved(to: point)
        try await Task.sleep(for: .milliseconds(400))
        #expect(model.state == .expanded)

        // Really leaving still closes it.
        model.mouseMoved(to: CGPoint(x: wide.midX, y: wide.minY - 200))
        try await Task.sleep(for: .milliseconds(400))
        #expect(model.state == .collapsed)
    }

    @Test func hoveringOpenTakesTheKeyboardAndClosingGivesItBack() async throws {
        let model = model()
        var took = 0, gaveBack = 0
        model.onWantsKeyboard = { took += 1 }
        model.onCollapse = { gaveBack += 1 }
        let center = CGPoint(x: geometry.centerX, y: geometry.screenFrame.maxY - 5)
        model.mouseMoved(to: center)
        try await Task.sleep(for: .seconds(NotchViewModel.hoverDelay + 0.2))
        #expect(model.state == .expanded)
        model.mouseMoved(to: center)
        #expect(took == 1)  // once per opening
        model.collapse()
        #expect(gaveBack == 1)
    }

    @Test func openingsTheUserDidNotAskForLeaveTheKeyboardAlone() {
        let model = model()
        var took = 0, gaveBack = 0
        model.onWantsKeyboard = { took += 1 }
        model.onCollapse = { gaveBack += 1 }
        model.handleAttention(.expand(duration: 5), from: "agents")
        #expect(model.state == .expanded && took == 0)
        model.collapse()
        #expect(gaveBack == 0)
    }
}
