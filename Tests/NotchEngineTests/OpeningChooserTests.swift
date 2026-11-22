import AppKit
import SwiftUI
import Testing
import NotchKit
@testable import NotchEngine

@MainActor @Observable
private final class StatusApp: NotchApp {
    let id: String
    let name: String
    let iconSystemName = "circle"
    var relevance: NotchRelevance?
    var claims = false

    init(_ id: String, _ relevance: NotchRelevance? = nil) {
        self.id = id
        self.name = id.capitalized
        self.relevance = relevance
    }

    func activate(context: NotchContext) {}
    func makeExpandedView() -> AnyView { AnyView(EmptyView()) }
    var claimsNotchOnOpen: Bool { claims }
}

@MainActor @Suite(.serialized) struct OpeningChooserTests {
    private let states = [
        OpeningChooser.AppState(id: "today", name: "Today", relevance: NotchRelevance("The day at a glance")),
        OpeningChooser.AppState(id: "calendar", name: "Calendar",
                                relevance: NotchRelevance("Meeting “1:1 with Michael Chen” starts in 3 min", urgent: true)),
        OpeningChooser.AppState(id: "music", name: "Music", relevance: nil),
    ]

    @Test func onlySomethingUrgentSwitches() {
        #expect(OpeningChooser.pick(apps: states, current: "music") == "calendar")
        #expect(OpeningChooser.pick(apps: states, current: "calendar") == nil)
        let calm = states.map { OpeningChooser.AppState(id: $0.id, name: $0.name, relevance: nil) }
        #expect(OpeningChooser.pick(apps: calm, current: "today") == nil)
    }

    // MARK: Opening

    private let geometry = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                         notchSize: CGSize(width: 185, height: 32), centerX: 756, hasNotch: true)

    private func hoverOpen(_ model: NotchViewModel) async throws {
        model.mouseMoved(to: CGPoint(x: geometry.centerX, y: geometry.screenFrame.maxY - 5))
        try await Task.sleep(for: .seconds(NotchViewModel.hoverDelay + 0.2))
    }

    @Test func aHoverOpeningShowsTheChosenApp() async throws {
        let model = NotchViewModel(apps: [StatusApp("today"), StatusApp("calendar")], geometry: geometry)
        model.chooseOpening = { _ in "calendar" }
        try await hoverOpen(model)
        // On a busy test machine the opening can land a little later.
        for _ in 0..<20 where model.selectedAppID != "calendar" { try await Task.sleep(for: .milliseconds(100)) }
        #expect(model.selectedAppID == "calendar")
    }

    @Test func anAppClaimingTheOpeningStillWins() async throws {
        let jobs = StatusApp("jobs")
        jobs.claims = true
        let model = NotchViewModel(apps: [StatusApp("today"), StatusApp("calendar"), jobs], geometry: geometry)
        model.chooseOpening = { _ in "calendar" }
        try await hoverOpen(model)
        #expect(model.selectedAppID == "jobs")
    }

    @Test func aLateChoiceDoesntSwitchUnderYou() async throws {
        let model = NotchViewModel(apps: [StatusApp("today"), StatusApp("calendar")], geometry: geometry)
        model.chooseOpening = { _ in
            try? await Task.sleep(for: .seconds(NotchViewModel.hoverDelay + NotchViewModel.choiceWindow + 0.3))
            return "calendar"
        }
        try await hoverOpen(model)
        try await Task.sleep(for: .seconds(NotchViewModel.choiceWindow + 0.4))
        #expect(model.selectedAppID == "today")
    }

    @Test func yourOwnPickBeatsTheChoice() async throws {
        let model = NotchViewModel(apps: [StatusApp("today"), StatusApp("calendar"), StatusApp("music")], geometry: geometry)
        model.chooseOpening = { _ in
            try? await Task.sleep(for: .seconds(NotchViewModel.hoverDelay + 0.4))
            return "calendar"
        }
        try await hoverOpen(model)
        model.select("music")
        try await Task.sleep(for: .milliseconds(500))
        #expect(model.selectedAppID == "music")
    }
}
