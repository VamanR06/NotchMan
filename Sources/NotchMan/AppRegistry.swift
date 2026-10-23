import NotchKit
import CalendarApp
import NowPlayingApp
import TasksApp
import JobsApp
import ChatApp
import TodayApp

/// The notch apps shown in the dock, in order. Add new apps here.
@MainActor
enum AppRegistry {
    static func makeApps() -> [any NotchApp] {
        [
            TodayApp(),
            CalendarApp(),
            TasksApp(),
            JobsApp(),
            ChatApp(),
            NowPlayingApp(),
        ]
    }
}
