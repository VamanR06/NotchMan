// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotchMan",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "NotchMan", targets: ["NotchMan"]),
        .library(name: "NotchKit", targets: ["NotchKit"]),
    ],
    dependencies: [
        // Terminal emulator for the in-notch Claude Code terminal (MIT).
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", .upToNextMinor(from: "1.20.0")),
    ],
    targets: [
        // SDK that every notch app imports.
        .target(name: "NotchKit"),
        // Host: notch window, hover, dock, settings.
        .target(name: "NotchEngine", dependencies: ["NotchKit"]),
        // Notch apps.
        .target(name: "CalendarApp", dependencies: ["NotchKit"], path: "Sources/Apps/CalendarApp"),
        .target(name: "NowPlayingApp", dependencies: ["NotchKit"], path: "Sources/Apps/NowPlayingApp"),
        .target(name: "TasksApp", dependencies: ["NotchKit"], path: "Sources/Apps/TasksApp"),
        .target(name: "JobsApp", dependencies: ["NotchKit"], path: "Sources/Apps/JobsApp"),
        .target(name: "ChatApp", dependencies: ["NotchKit", "SwiftTerm"], path: "Sources/Apps/ChatApp"),
        .target(name: "TodayApp", dependencies: ["NotchKit"], path: "Sources/Apps/TodayApp"),
        // App shell: wires the registry of apps into the engine.
        .executableTarget(
            name: "NotchMan",
            dependencies: ["NotchKit", "NotchEngine", "CalendarApp", "NowPlayingApp", "TasksApp", "JobsApp", "ChatApp", "TodayApp"]
        ),
        .testTarget(name: "NotchKitTests", dependencies: ["NotchKit"]),
        .testTarget(name: "CalendarAppTests", dependencies: ["CalendarApp"]),
        .testTarget(name: "NotchEngineTests", dependencies: ["NotchEngine", "NotchKit"]),
        .testTarget(name: "TasksAppTests", dependencies: ["TasksApp"]),
        .testTarget(name: "JobsAppTests", dependencies: ["JobsApp"]),
        .testTarget(name: "ChatAppTests", dependencies: ["ChatApp"]),
        .testTarget(name: "NowPlayingAppTests", dependencies: ["NowPlayingApp"]),
        .testTarget(name: "TodayAppTests", dependencies: ["TodayApp", "NotchKit"]),
    ]
)
