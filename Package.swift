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
        // App shell: wires the registry of apps into the engine.
        .executableTarget(
            name: "NotchMan",
            dependencies: ["NotchKit", "NotchEngine", "CalendarApp", "NowPlayingApp"]
        ),
    ]
)
