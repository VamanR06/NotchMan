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

    init(_ id: String, width: CGFloat = 620) {
        self.id = id
        self.name = id
        self.expandedWidth = width
    }

    func activate(context: NotchContext) {}
    func makeExpandedView() -> AnyView { AnyView(EmptyView()) }
}

@MainActor @Suite struct DockLayoutTests {
    private let geometry = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                         notchSize: CGSize(width: 185, height: 32), centerX: 756, hasNotch: true)

    @Test func roomBesideALaptopNotchUsesTheNarrowestApp() {
        let apps = [SizedApp("today", width: 700), SizedApp("calendar"), SizedApp("chat", width: 720)]
        let model = NotchViewModel(apps: apps, geometry: geometry)
        // (620 − 2 × (14 + 16) − 185) / 2
        #expect(model.dockWidth == 187.5)
    }

    @Test func appsThatFitAreAllShownWithoutTheAppsButton() {
        let layout = DockLayout.fit(count: 5, selected: 0, width: 187.5)
        #expect(layout.shown == Array(0..<5))
        #expect(!layout.hasAppsButton)
    }

    @Test func eightAppsBesideALaptopNotchShowFiveAndTheAppsButton() {
        let layout = DockLayout.fit(count: 8, selected: 0, width: 187.5)
        #expect(layout.shown == Array(0..<5))
        #expect(layout.hasAppsButton)
        let used = CGFloat(layout.shown.count) * (DockLayout.itemWidth + DockLayout.spacing) + DockLayout.appsButtonWidth
        #expect(used <= 187.5)
    }

    @Test func theSelectedAppIsNeverLeftOut() {
        let layout = DockLayout.fit(count: 8, selected: 7, width: 187.5)
        #expect(layout.shown == [0, 1, 2, 3, 7])
    }

    @Test func choosingAnAppOrClosingTheNotchClosesTheGrid() {
        let model = NotchViewModel(apps: [SizedApp("a"), SizedApp("b")], geometry: geometry)
        model.showingAppGrid = true
        model.select("b")
        #expect(!model.showingAppGrid)
        model.showingAppGrid = true
        model.collapse()
        #expect(!model.showingAppGrid)
    }
}
