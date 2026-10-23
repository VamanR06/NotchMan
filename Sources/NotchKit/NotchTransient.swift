import SwiftUI

/// A short-lived status the engine shows in place of the collapsed notch's chips: a system HUD (volume,
/// brightness, battery), a finished download, "✓ added to project", … Showing another replaces it.
public struct NotchTransient: Sendable, Equatable {
    /// Groups updates of the same thing (holding the volume key updates one HUD instead of stacking).
    public var id: String
    public var systemImage: String
    public var text: String?
    /// 0…1 shows a level bar on the right instead of text.
    public var level: Double?
    public var tint: Color
    public var duration: TimeInterval

    public init(id: String, systemImage: String, text: String? = nil, level: Double? = nil,
                tint: Color = .white, duration: TimeInterval = 1.5) {
        self.id = id
        self.systemImage = systemImage
        self.text = text
        self.level = level.map { min(max($0, 0), 1) }
        self.tint = tint
        self.duration = duration
    }
}
