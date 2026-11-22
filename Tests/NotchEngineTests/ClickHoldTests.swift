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

/// Once you type in the open notch, its window takes clicks even where it's empty, so a busy moment can't let a
/// click meant for it fall through to the app behind; a click on the empty part closes it like any click outside.
@MainActor @Suite struct ClickHoldTests {
    private let geometry = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                         notchSize: CGSize(width: 185, height: 32), centerX: 756, hasNotch: true)

    @Test func typingHoldsClicksUntilItCloses() {
        let model = NotchViewModel(apps: [PlainApp("a")], geometry: geometry)
        #expect(!model.holdsClicks)
        model.expand()
        #expect(!model.holdsClicks, "a hover opening lets clicks beside it through")
        model.userTyped()
        #expect(model.holdsClicks)
        // A click well below the notch's shape counts as outside and closes it.
        model.clickedOutside(at: CGPoint(x: geometry.centerX, y: 300))
        #expect(model.state == .collapsed && !model.holdsClicks)
    }
}
