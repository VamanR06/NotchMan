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
    @Test func roomBesideALaptopNotchUsesTheNarrowestApp() {
        let geometry = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                     notchSize: CGSize(width: 185, height: 32), centerX: 756, hasNotch: true)
        let apps = [SizedApp("today", width: 700), SizedApp("calendar"), SizedApp("chat", width: 720)]
        let model = NotchViewModel(apps: apps, geometry: geometry)
        // (620 − 2 × (14 + 16) − 185) / 2
        #expect(model.dockWidth == 187.5)
    }

    @Test func fewAppsKeepFullSizeIcons() {
        let layout = DockLayout.fit(count: 5, selected: 0, width: 187.5)
        #expect(layout.itemWidth == 28)
        #expect(layout.shown == Array(0..<5))
        #expect(layout.overflow.isEmpty)
    }

    @Test func eightAppsBesideALaptopNotchAllShowTighter() {
        let layout = DockLayout.fit(count: 8, selected: 7, width: 187.5)
        #expect(layout.itemWidth == 22)
        #expect(layout.shown == Array(0..<8))
        #expect(layout.overflow.isEmpty)
        #expect(8 * layout.itemWidth + 7 * layout.spacing <= 187.5)
    }

    @Test func tooManyAppsMoveTheRestIntoAMenu() {
        let layout = DockLayout.fit(count: 10, selected: 1, width: 187.5)
        #expect(layout.shown == Array(0..<7))
        #expect(layout.overflow == [7, 8, 9])
        let used = CGFloat(layout.shown.count) * (layout.itemWidth + layout.spacing) + DockLayout.moreWidth
        #expect(used <= 187.5)
    }

    @Test func theSelectedAppIsNeverHidden() {
        let layout = DockLayout.fit(count: 10, selected: 9, width: 187.5)
        #expect(layout.shown.last == 9)
        #expect(layout.overflow == [6, 7, 8])
    }
}
