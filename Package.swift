// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotchMan",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "NotchMan", targets: ["NotchMan"]),
        .library(name: "NotchKit", targets: ["NotchKit"]),
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
        .target(name: "ChatApp", dependencies: ["NotchKit"], path: "Sources/Apps/ChatApp"),
        // App shell: wires the registry of apps into the engine.
        .executableTarget(
            name: "NotchMan",
            dependencies: ["NotchKit", "NotchEngine", "CalendarApp", "NowPlayingApp", "TasksApp", "JobsApp", "ChatApp"]
        ),
        .testTarget(name: "NotchKitTests", dependencies: ["NotchKit"]),
        .testTarget(name: "CalendarAppTests", dependencies: ["CalendarApp"]),
        .testTarget(name: "TasksAppTests", dependencies: ["TasksApp"]),
        .testTarget(name: "JobsAppTests", dependencies: ["JobsApp"]),
        .testTarget(name: "ChatAppTests", dependencies: ["ChatApp"]),
    ]
)
