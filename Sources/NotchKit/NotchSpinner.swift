import AppKit
import SwiftUI

/// A spinner that stays visible on the black notch (the system one draws dark gray there).
///
/// It turns with a Core Animation rotation, which the window server runs on its own: NotchMan does no work per
/// frame. (Driving it from SwiftUI redrew it up to 120 times a second whenever an agent was working.)
public struct NotchSpinner: View {
    private let size: CGFloat
    private let color: Color
    private let lineWidth: CGFloat

    public init(size: CGFloat = 12, color: Color = .white, lineWidth: CGFloat = 2) {
        self.size = size
        self.color = color
        self.lineWidth = lineWidth
    }

    public var body: some View {
        SpinnerLayer(color: NSColor(color), lineWidth: lineWidth)
            .frame(width: size, height: size)
    }
}

private struct SpinnerLayer: NSViewRepresentable {
    let color: NSColor
    let lineWidth: CGFloat

    func makeNSView(context: Context) -> SpinnerView { SpinnerView() }

    func updateNSView(_ view: SpinnerView, context: Context) {
        view.configure(color: color, lineWidth: lineWidth)
    }
}

/// An open ring (70% of a circle) turning once every 0.9s.
public final class SpinnerView: NSView {
    private let ring = CAShapeLayer()
    private static let spin = "spin"

    public override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        ring.fillColor = nil
        ring.lineCap = .round
        ring.strokeStart = 0.15
        ring.strokeEnd = 0.85
        layer?.addSublayer(ring)
        configure(color: .white, lineWidth: 2)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(color: NSColor, lineWidth: CGFloat) {
        ring.strokeColor = color.cgColor
        ring.lineWidth = lineWidth
        needsLayout = true
    }

    /// Clicks go to whatever the spinner sits in (a button, a row).
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = bounds
        ring.path = CGPath(ellipseIn: bounds.insetBy(dx: ring.lineWidth / 2, dy: ring.lineWidth / 2), transform: nil)
        CATransaction.commit()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        ring.contentsScale = window?.backingScaleFactor ?? 2
        guard ring.animation(forKey: Self.spin) == nil else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi  // clockwise
        spin.duration = 0.9
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        // Smooth enough for something this small, at a fraction of the display's 120Hz.
        spin.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        ring.add(spin, forKey: Self.spin)
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        ring.contentsScale = window?.backingScaleFactor ?? 2
    }
}
