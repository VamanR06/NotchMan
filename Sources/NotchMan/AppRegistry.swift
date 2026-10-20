import NotchKit
import CalendarApp
import NowPlayingApp
import TasksApp
import JobsApp

/// The notch apps shown in the dock, in order. Add new apps here.
@MainActor
enum AppRegistry {
    static func makeApps() -> [any NotchApp] {
        [
            CalendarApp(),
            TasksApp(),
            JobsApp(),
            NowPlayingApp(),
        ]
    }
}
