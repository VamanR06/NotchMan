import AppKit
import SwiftUI
import Testing
import NotchKit
@testable import NotchEngine

@MainActor @Observable
private final class DockApp: NotchApp {
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

@MainActor @Suite struct DockTests {
    private let geometry = NotchGeometry(
        screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        notchSize: CGSize(width: 185, height: 32), centerX: 756, hasNotch: true)

    @Test func everythingShowsWhenItFits() {
        let slots = NotchViewModel.dockSlots(count: 4, selected: 2, fitting: 5)
        #expect(slots.indices == [0, 1, 2, 3])
        #expect(!slots.overflow)
    }

    @Test func theLastSlotBecomesAllAppsWhenTheyDoNot() {
        let slots = NotchViewModel.dockSlots(count: 8, selected: 1, fitting: 5)
        #expect(slots.indices == [0, 1, 2, 3])
        #expect(slots.overflow)
    }

    @Test func aHiddenSelectedAppTakesTheSlotBeforeAllApps() {
        let slots = NotchViewModel.dockSlots(count: 8, selected: 6, fitting: 5)
        #expect(slots.indices == [0, 1, 2, 6])
    }

    @Test func eightAppsNoLongerRunUnderTheNotch() {
        let apps = (1...8).map { DockApp("app\($0)") }
        let model = NotchViewModel(apps: apps, geometry: geometry)
        model.expand()
        let dock = model.dockApps
        #expect(dock.overflow)
        let slots = CGFloat(dock.shown.count + 1)
        let rowWidth = slots * model.dockItemWidth + (slots - 1) * model.dockSpacing
        #expect(rowWidth <= model.expandedWingWidth)
    }

    @Test func choosingAnAppClosesAllAppsAndSoDoesClosingTheNotch() {
        let model = NotchViewModel(apps: (1...8).map { DockApp("app\($0)") }, geometry: geometry)
        model.expand()
        model.toggleLauncher()
        #expect(model.isLauncherOpen)
        model.select("app7")
        #expect(!model.isLauncherOpen)
        #expect(model.dockApps.shown.map(\.id).contains("app7"))
        model.toggleLauncher()
        model.collapse()
        #expect(!model.isLauncherOpen)
    }
}
