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
    init(_ id: String) { self.id = id; self.name = id }
    func activate(context: NotchContext) {}
    func makeExpandedView() -> AnyView { AnyView(EmptyView()) }
}

/// With a notch on each display, they act as one: the same app and pin everywhere, and only one open at a time.
@MainActor @Suite struct SyncedNotchesTests {
    private let apps: [any NotchApp] = [PlainApp("a"), PlainApp("b"), PlainApp("c")]

    private func geometry(x: CGFloat) -> NotchGeometry {
        NotchGeometry(screenFrame: CGRect(x: x, y: 0, width: 1512, height: 982),
                      notchSize: CGSize(width: 185, height: 32), centerX: x + 756, hasNotch: x == 0)
    }

    /// Two notches wired the way the engine wires them.
    private func pair() -> (NotchViewModel, NotchViewModel) {
        let one = NotchViewModel(apps: apps, geometry: geometry(x: 0))
        let two = NotchViewModel(apps: apps, geometry: geometry(x: 1512))
        for model in [one, two] {
            model.onSharedChange = { NotchEngine.sync([one, two], from: $0) }
            model.onExpand = { opened in [one, two].forEach { NotchEngine.close($0, for: opened) } }
        }
        return (one, two)
    }

    @Test func openingOneClosesTheOther() {
        let (one, two) = pair()
        one.expand()
        #expect(one.state == .expanded && two.state == .collapsed)
        two.expand()
        #expect(two.state == .expanded && one.state == .collapsed)
        // Expanding the one already open doesn't close anything.
        two.expand()
        #expect(two.state == .expanded && one.state == .collapsed)
    }

    @Test func theAppShownAndThePinFollowEverywhere() {
        let (one, two) = pair()
        one.select("c")
        #expect(two.selectedAppID == "c")
        two.isPinned = true
        #expect(one.isPinned)
        two.select("b")
        #expect(one.selectedAppID == "b")
        one.isPinned = false
        #expect(!two.isPinned)
    }

    @Test func aPinnedNotchStillClosesWhenAnotherOpens() {
        let (one, two) = pair()
        one.isPinned = true
        one.expand()
        two.expand()
        #expect(one.state == .collapsed && two.state == .expanded && two.isPinned)
    }
}
