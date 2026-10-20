import NotchKit
import CalendarApp
import NowPlayingApp
import TasksApp

/// The notch apps shown in the dock, in order. Add new apps here.
@MainActor
enum AppRegistry {
    static func makeApps() -> [any NotchApp] {
        [
            CalendarApp(),
            TasksApp(),
            NowPlayingApp(),
        ]
    }
}
