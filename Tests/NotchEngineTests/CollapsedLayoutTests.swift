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

    private func activity(_ priority: Int, _ label: String, _ color: Color) -> NotchActivity {
        NotchActivity(priority: priority) {
            Circle().fill(color).frame(width: 18, height: 18)
        } trailing: {
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
        } compact: {
            RoundedRectangle(cornerRadius: 4).fill(color).frame(width: 18, height: 18)
        }
    }

    @Test func topActivityPlusTwoCompactExtras() throws {
        let model = NotchViewModel(apps: [
            FakeApp("music", activity: activity(10, "♪♪", .green)),
            FakeApp("chat", activity: activity(14, "GPT", .white)),
            FakeApp("calendar", activity: activity(5, "5m", .orange)),
            FakeApp("idle", activity: nil),
        ], geometry: geometry)

        #expect(model.topActivity?.priority == 14)
        #expect(model.extraActivities.map(\.priority) == [10, 5])
        // Both sides grow by one slot so the shape stays centered on the notch.
        #expect(model.collapsedSideWidth == model.activitySideWidth + model.extraSlotWidth)
        #expect(model.shapeSize.width == 185 + 2 * model.topCornerRadius + 2 * model.collapsedSideWidth)

        try render(model, to: "collapsed-3-activities.png")
    }

    @Test func singleActivityKeepsOriginalWidth() throws {
        let model = NotchViewModel(apps: [FakeApp("music", activity: activity(10, "♪♪", .green))], geometry: geometry)
        #expect(model.extraActivities.isEmpty)
        #expect(model.collapsedSideWidth == model.activitySideWidth)
        try render(model, to: "collapsed-1-activity.png")
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
            .frame(width: model.windowSize.width, height: 60)
            .background(Color(white: 0.85))
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
