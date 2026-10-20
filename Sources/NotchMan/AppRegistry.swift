import NotchKit
import CalendarApp
import NowPlayingApp

/// The notch apps shown in the dock, in order. Add new apps here.
@MainActor
enum AppRegistry {
    static func makeApps() -> [any NotchApp] {
        [
            CalendarApp(),
            NowPlayingApp(),
        ]
    }
}
