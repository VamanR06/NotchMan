import AppKit
import SwiftUI
import Testing
import NotchKit
@testable import NotchEngine

@MainActor @Observable
private final class FakeApp: NotchApp {
    let id: String
    let name: String
    let iconSystemName = "circle"
    var activity: NotchActivity?

    init(_ id: String, activity: NotchActivity?) {
        self.id = id
        self.name = id
        self.activity = activity
    }

    func activate(context: NotchContext) {}
    func makeExpandedView() -> AnyView { AnyView(EmptyView()) }
}

@MainActor @Suite struct CollapsedLayoutTests {
    private let geometry = NotchGeometry(
        screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        notchSize: CGSize(width: 185, height: 32), centerX: 756, hasNotch: true)

    private func chip(_ priority: Int, _ text: String, _ symbol: String, _ tint: Color = .white) -> NotchActivity {
        NotchActivity(priority: priority) { NotchChip(text, systemImage: symbol, tint: tint) }
    }

    private func music(_ priority: Int) -> NotchActivity {
        NotchActivity(priority: priority) {
            RoundedRectangle(cornerRadius: 5).fill(.purple).frame(width: 20, height: 20)
        } trailing: {
            HStack(spacing: 2) { ForEach(0..<4) { i in Capsule().fill(.green).frame(width: 2.5, height: CGFloat(5 + i * 3)) } }
        } chip: {
            RoundedRectangle(cornerRadius: 4).fill(.purple).frame(width: 16, height: 16)
        }
    }

    @Test func singleChipExtendsOneSideOnly() throws {
        let model = NotchViewModel(apps: [FakeApp("tasks", activity: chip(3, "2 late", "checklist", .red))], geometry: geometry)
        let layout = model.collapsedLayout
        #expect(layout.right.count == 1 && layout.left.isEmpty && layout.split == nil)
        #expect(layout.leftWidth == 0)
        #expect(model.shapeOffsetX == layout.rightWidth / 2)
        // The hit area follows the shifted shape.
        #expect(model.hitRect.midX == geometry.centerX + model.shapeOffsetX)
        try render(model, to: "collapsed-one-chip.png")
    }

    @Test func musicOnTopWithChipsOnTheOutside() throws {
        let model = NotchViewModel(apps: [
            FakeApp("music", activity: music(10)),
            FakeApp("chat", activity: chip(14, "GPT", "circle.dotted")),
            FakeApp("tasks", activity: chip(3, "2 late", "checklist", .red)),
            FakeApp("calendar", activity: chip(5, "25m", "calendar")),
        ], geometry: geometry)
        let layout = model.collapsedLayout
        // Chat outranks music, so music isn't split: chips right, left, right.
        #expect(layout.split == nil)
        #expect(layout.right.map(\.priority) == [14, 5] && layout.left.map(\.priority) == [10])
        try render(model, to: "collapsed-three-chips.png")
    }

    @Test func musicSplitWhenOnTop() throws {
        let model = NotchViewModel(apps: [
            FakeApp("music", activity: music(10)),
            FakeApp("tasks", activity: chip(3, "3 today", "checklist")),
            FakeApp("calendar", activity: chip(5, "25m", "calendar")),
        ], geometry: geometry)
        let layout = model.collapsedLayout
        #expect(layout.split?.priority == 10)
        #expect(layout.right.map(\.priority) == [5] && layout.left.map(\.priority) == [3])
        #expect(model.shapeOffsetX == 0)
        try render(model, to: "collapsed-music-split.png")
    }

    @Test func atMostThreeActivities() {
        let model = NotchViewModel(apps: (0..<5).map { FakeApp("a\($0)", activity: chip($0, "\($0)", "circle")) },
                                   geometry: geometry)
        let layout = model.collapsedLayout
        #expect(layout.left.count + layout.right.count == 3)
    }

    @Test func spinnerIsVisibleOnBlack() throws {
        let renderer = ImageRenderer(content: NotchSpinner(size: 24).padding(8).background(.black))
        renderer.scale = 2
        let tiff = try #require(renderer.nsImage?.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        // Some pixel must be bright: the system spinner rendered near-black here.
        var brightest: CGFloat = 0
        for x in 0..<rep.pixelsWide { for y in 0..<rep.pixelsHigh {
            brightest = max(brightest, rep.colorAt(x: x, y: y)?.brightnessComponent ?? 0)
        } }
        #expect(brightest > 0.9)
    }

    /// Writes a PNG of the collapsed notch for eyeballing (into the package's build/dev).
    private func render(_ model: NotchViewModel, to name: String) throws {
        let view = NotchRootView(model: model, openSettings: {})
            .frame(width: 700, height: 60)
            .background(Color(white: 0.85))
        // First pass measures the chips (they size to their content); the second draws with those widths.
        _ = ImageRenderer(content: view).nsImage
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let tiff = try #require(renderer.nsImage?.tiffRepresentation)
        let data = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "../../build/dev").standardizedFileURL
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: dir.appending(path: name))
    }
}

@MainActor @Suite struct HoldOpenTests {
    private let geometry = NotchGeometry(
        screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        notchSize: CGSize(width: 185, height: 32), centerX: 756, hasNotch: true)

    @Test func heldNotchIgnoresMouseLeavingButClosesOnOutsideClick() async throws {
        let model = NotchViewModel(apps: [FakeApp("chat", activity: nil)], geometry: geometry)
        model.expand()
        model.heldApps = ["chat"]
        let outside = CGPoint(x: 100, y: 100)
        model.mouseMoved(to: outside)
        try await Task.sleep(for: .milliseconds(400))
        #expect(model.state == .expanded, "mouse leaving shouldn't close a held notch")
        model.clickedOutside(at: outside)
        #expect(model.state == .collapsed)
    }

    @Test func unheldNotchClosesWhenTheMouseLeaves() async throws {
        let model = NotchViewModel(apps: [FakeApp("chat", activity: nil)], geometry: geometry)
        model.expand()
        model.mouseMoved(to: CGPoint(x: 100, y: 100))
        // Collapses after a short delay; allow for a busy test run.
        for _ in 0..<20 where model.state == .expanded { try await Task.sleep(for: .milliseconds(100)) }
        #expect(model.state == .collapsed)
    }
}

@MainActor @Suite(.serialized) struct HoverDelayTests {
    private let geometry = NotchGeometry(
        screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        notchSize: CGSize(width: 185, height: 32), centerX: 756, hasNotch: true)
    private let onNotch = CGPoint(x: 756, y: 975)
    private let away = CGPoint(x: 756, y: 600)

    @Test func brushingPastDoesNotOpen() async throws {
        UserDefaults.standard.set(0.35, forKey: NotchViewModel.hoverDelayKey)
        defer { UserDefaults.standard.removeObject(forKey: NotchViewModel.hoverDelayKey) }
        let model = NotchViewModel(apps: [FakeApp("a", activity: nil)], geometry: geometry)
        model.mouseMoved(to: onNotch)
        try await Task.sleep(for: .milliseconds(150))
        model.mouseMoved(to: away)                       // left before the delay
        try await Task.sleep(for: .milliseconds(400))
        #expect(model.state == .collapsed)
    }

    @Test func restingOnTheNotchOpensIt() async throws {
        UserDefaults.standard.set(0.35, forKey: NotchViewModel.hoverDelayKey)
        defer { UserDefaults.standard.removeObject(forKey: NotchViewModel.hoverDelayKey) }
        let model = NotchViewModel(apps: [FakeApp("a", activity: nil)], geometry: geometry)
        model.mouseMoved(to: onNotch)
        for _ in 0..<20 where model.state == .collapsed { try await Task.sleep(for: .milliseconds(100)) }
        #expect(model.state == .expanded)
    }

    @Test func delayIsClampedToASaneRange() {
        UserDefaults.standard.set(-1.0, forKey: NotchViewModel.hoverDelayKey)
        #expect(NotchViewModel.hoverDelay == 0.05)
        UserDefaults.standard.set(9.0, forKey: NotchViewModel.hoverDelayKey)
        #expect(NotchViewModel.hoverDelay == 2)
        UserDefaults.standard.removeObject(forKey: NotchViewModel.hoverDelayKey)
        #expect(NotchViewModel.hoverDelay == NotchViewModel.defaultHoverDelay)
    }
}
