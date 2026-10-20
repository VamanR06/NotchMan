import SwiftUI

/// A spinner that stays visible on the black notch (the system one draws dark gray there).
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
        TimelineView(.animation) { context in
            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9
            Circle()
                .trim(from: 0.15, to: 0.85)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(turn * 360))
        }
        .frame(width: size, height: size)
    }
}
