import AppKit
import NotchKit

/// Owns the notch window and hosts the registered apps.
@MainActor
public final class NotchEngine {
    public let apps: [any NotchApp]

    public init(apps: [any NotchApp]) {
        self.apps = apps
    }

    public func start() {}

    public func stop() {}
}
