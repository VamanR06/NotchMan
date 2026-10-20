import SwiftUI
import NotchKit

@MainActor @Observable
public final class NowPlayingApp: NotchApp {
    public let id = "nowplaying"
    public let name = "Now Playing"
    public let iconSystemName = "music.note"

    public init() {}

    public func activate(context: NotchContext) {}

    public func makeExpandedView() -> AnyView {
        AnyView(Text("Now Playing").foregroundStyle(.white))
    }
}
