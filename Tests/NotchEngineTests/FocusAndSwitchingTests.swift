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

@MainActor @Observable
private final class ClaimingApp: NotchApp {
    let id: String
    let name: String
    let iconSystemName = "briefcase"
    var claims = false
    var willOpenCalls = 0

    init(_ id: String) {
        self.id = id
        self.name = id
    }

    func activate(context: NotchContext) {}
    func makeExpandedView() -> AnyView { AnyView(EmptyView()) }
    func notchWillOpen() { willOpenCalls += 1 }
    var claimsNotchOnOpen: Bool { claims }
    var switchedTo: [String] = []
    func userSwitched(to appID: String) { switchedTo.append(appID) }
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
        // Closes after 250ms; give a busy test machine some room.
        for _ in 0..<20 where model.state != .collapsed { try await Task.sleep(for: .milliseconds(100)) }
        #expect(model.state == .collapsed)
    }

    /// Opens by hovering, with the engine's part simulated: asking for the keyboard makes the panel key.
    private func hoverOpen(_ model: NotchViewModel, asked: @escaping () -> Void = {}) async throws -> CGPoint {
        model.onWantsKeyboard = { [weak model] in
            asked()
            model?.keyboardTaken()
        }
        let center = CGPoint(x: geometry.centerX, y: geometry.screenFrame.maxY - 5)
        model.mouseMoved(to: center)
        try await Task.sleep(for: .seconds(NotchViewModel.hoverDelay + 0.2))
        return center
    }

    private func waitForCollapse(_ model: NotchViewModel) async throws {
        for _ in 0..<20 where model.state != .collapsed { try await Task.sleep(for: .milliseconds(100)) }
    }

    @Test func hoveringOpenTakesTheKeyboardOnce() async throws {
        let model = model()
        var asked = 0
        let center = try await hoverOpen(model) { asked += 1 }
        #expect(model.state == .expanded && model.tookKeyboard)
        model.mouseMoved(to: center)
        #expect(asked == 1, "once per opening")
    }

    @Test func leavingWithoutTypingClosesAndGivesTheKeyboardBack() async throws {
        let model = model()
        var gaveBack = 0
        model.onCollapse = { gaveBack += 1 }
        let center = try await hoverOpen(model)
        model.mouseMoved(to: CGPoint(x: center.x, y: center.y - 400))
        try await waitForCollapse(model)
        #expect(model.state == .collapsed && gaveBack == 1)
        #expect(!model.tookKeyboard, "the next opening starts without it")
    }

    @Test func typingKeepsItOpenWhenTheMouseLeaves() async throws {
        let model = model()
        var gaveBack = 0
        model.onCollapse = { gaveBack += 1 }
        let center = try await hoverOpen(model)
        model.userTyped()
        model.mouseMoved(to: CGPoint(x: center.x, y: center.y - 400))
        try await Task.sleep(for: .milliseconds(600))
        #expect(model.state == .expanded, "held while you're typing in it")
        model.clickedOutside(at: CGPoint(x: center.x, y: center.y - 400))
        #expect(model.state == .collapsed && gaveBack == 1, "a click outside closes it and gives the keyboard back")
    }

    @Test func typingOnAClosedNotchHoldsNothing() {
        let model = model()
        model.userTyped()
        #expect(!model.keyboardHeld)
    }

    @Test func aClosedNotchNeverTakesTheKeyboard() {
        let model = model()
        model.keyboardTaken()
        #expect(!model.tookKeyboard)
    }

    @Test func anAppCanClaimAHoverOpening() async throws {
        let jobs = ClaimingApp("jobs")
        let model = NotchViewModel(apps: [SizedApp("agents", width: 620), jobs], geometry: geometry)
        let center = CGPoint(x: geometry.centerX, y: geometry.screenFrame.maxY - 5)
        model.mouseMoved(to: center)
        #expect(jobs.willOpenCalls == 1)
        // Its check finishes after the notch has opened: the second look still picks it up.
        try await Task.sleep(for: .seconds(NotchViewModel.hoverDelay + 0.2))
        #expect(model.selectedAppID == "agents")
        jobs.claims = true
        try await Task.sleep(for: .seconds(1.3))
        #expect(model.selectedAppID == "jobs")
    }

    @Test func aLateClaimDoesNotOverrideTheUsersChoice() async throws {
        let jobs = ClaimingApp("jobs")
        let model = NotchViewModel(apps: [SizedApp("agents", width: 620), SizedApp("music", width: 620), jobs], geometry: geometry)
        model.mouseMoved(to: CGPoint(x: geometry.centerX, y: geometry.screenFrame.maxY - 5))
        try await Task.sleep(for: .seconds(NotchViewModel.hoverDelay + 0.2))
        model.select("music")
        jobs.claims = true
        try await Task.sleep(for: .seconds(1.3))
        #expect(model.selectedAppID == "music")
    }

    @Test func onlyYourOwnSwitchesAreReportedToApps() {
        let jobs = ClaimingApp("jobs")
        let model = NotchViewModel(apps: [SizedApp("chat", width: 620), jobs], geometry: geometry)
        model.expand()
        model.select("jobs")  // NotchMan's doing (a claim, a notification)
        #expect(jobs.switchedTo.isEmpty)
        model.userSelect("chat")  // the dock, ⌘-number, a command
        #expect(jobs.switchedTo == ["chat"] && model.selectedAppID == "chat")
    }

    @Test func openingsTheUserDidNotAskForLeaveTheKeyboardAlone() {
        let model = model()
        var gaveBack = 0
        model.onCollapse = { gaveBack += 1 }
        model.handleAttention(.expand(duration: 5), from: "agents")
        #expect(model.state == .expanded && !model.tookKeyboard)
        model.collapse()
        #expect(gaveBack == 0)
    }
}
