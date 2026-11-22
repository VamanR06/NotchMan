import AppKit
import SwiftUI
import Testing
import NotchKit
@testable import NotchEngine

@MainActor @Observable
private final class PlainApp: NotchApp {
    let id: String
    let name: String
    let iconSystemName = "circle"
    var deactivated = false

    init(_ id: String) {
        self.id = id
        self.name = id
    }

    func activate(context: NotchContext) {}
    func deactivate() { deactivated = true }
    func makeExpandedView() -> AnyView { AnyView(EmptyView()) }
}

/// Generated notch apps join and leave the dock while NotchMan runs.
@MainActor @Suite struct DynamicAppsTests {
    @Test func appsCanBeAddedAndRemoved() {
        let engine = NotchEngine(apps: [PlainApp("today")])
        let pomodoro = PlainApp("mod.pomodoro")
        engine.add(pomodoro)
        #expect(engine.apps.map(\.id) == ["today", "mod.pomodoro"])
        engine.add(PlainApp("mod.pomodoro"))
        #expect(engine.apps.count == 2, "not twice")
        engine.remove(appID: "mod.pomodoro")
        #expect(engine.apps.map(\.id) == ["today"] && pomodoro.deactivated)
    }

    @Test func removingTheShownAppShowsAnother() {
        let geometry = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                     notchSize: CGSize(width: 185, height: 32), centerX: 756, hasNotch: true)
        let model = NotchViewModel(apps: [PlainApp("today"), PlainApp("mod.x")], geometry: geometry)
        model.select("mod.x")
        model.apps = [PlainApp("today")]
        #expect(model.selectedAppID == "today")
    }
}
