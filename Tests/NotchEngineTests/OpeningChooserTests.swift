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

    @Test func theRequestDescribesEveryAppRedacted() {
        let request = OpeningChooser.request(apps: states, current: "today",
                                             context: IntentContext(frontmostApp: "Zoom", timeOfDay: "weekday morning"),
                                             redactor: Redactor(identity: []))
        guard case .choice(let options)? = request.questions["app"]?.kind else {
            Issue.record("expected one choice")
            return
        }
        #expect(Set(options.keys) == ["keep", "today", "calendar", "music"])
        #expect(options["music"] == "Music (nothing new)")
        let text = String(decoding: try! JSONEncoder().encode(request.state), as: UTF8.self)
        #expect(!text.contains("Michael") && text.contains("starts in 3 min"), "\(text)")
    }

    private func answer(_ choice: String, _ probability: Double) -> [String: JevAnswer] {
        ["app": .choice(choice, confidence: probability, probabilities: [choice: probability])]
    }

    @Test func aSurePickElsewhereIsTaken() {
        #expect(OpeningChooser.pick(answer("calendar", 0.8), current: "today", apps: states) == "calendar")
        #expect(OpeningChooser.pick(answer("calendar", 0.4), current: "today", apps: states) == nil, "not sure enough")
        #expect(OpeningChooser.pick(answer("keep", 0.9), current: "today", apps: states) == nil)
        #expect(OpeningChooser.pick(answer("today", 0.9), current: "today", apps: states) == nil, "already there")
        #expect(OpeningChooser.pick(answer("ghost", 0.9), current: "today", apps: states) == nil)
    }

    @Test func withoutJevOnlySomethingUrgentSwitches() {
        #expect(OpeningChooser.localPick(apps: states, current: "music") == "calendar")
        #expect(OpeningChooser.localPick(apps: states, current: "calendar") == nil)
        let calm = states.map { OpeningChooser.AppState(id: $0.id, name: $0.name, relevance: nil) }
        #expect(OpeningChooser.localPick(apps: calm, current: "today") == nil)
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
