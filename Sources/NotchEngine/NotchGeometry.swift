import AppKit

/// Where the hardware notch is (or a virtual one on displays without a notch).
struct NotchGeometry: Equatable {
    /// Screen frame in global coordinates.
    let screenFrame: CGRect
    /// Size of the physical notch cutout.
    let notchSize: CGSize
    /// Horizontal center of the notch in global coordinates.
    let centerX: CGFloat
    let hasNotch: Bool

    var top: CGFloat { screenFrame.maxY }

    /// Prefers the built-in display with a notch, falling back to the main screen.
    @MainActor
    static func current() -> (NSScreen, NotchGeometry)? {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return nil }
        return (screen, NotchGeometry(screen: screen))
    }

    init(screenFrame: CGRect, notchSize: CGSize, centerX: CGFloat, hasNotch: Bool) {
        self.screenFrame = screenFrame
        self.notchSize = notchSize
        self.centerX = centerX
        self.hasNotch = hasNotch
    }

    @MainActor
    init(screen: NSScreen) {
        let frame = screen.frame
        screenFrame = frame
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let width = frame.width - left.width - right.width
            notchSize = CGSize(width: width, height: screen.safeAreaInsets.top)
            centerX = frame.minX + left.width + width / 2
            hasNotch = true
        } else {
            let menuBarHeight = frame.maxY - screen.visibleFrame.maxY
            notchSize = CGSize(width: 185, height: max(menuBarHeight, 24))
            centerX = frame.midX
            hasNotch = false
        }
    }

    /// A rect of `size` hanging from the top of the screen, centered on the notch.
    func rect(hanging size: CGSize) -> CGRect {
        CGRect(x: centerX - size.width / 2, y: top - size.height, width: size.width, height: size.height)
    }
}
