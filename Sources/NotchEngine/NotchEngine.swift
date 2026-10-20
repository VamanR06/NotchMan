import AppKit
import SwiftUI
import NotchKit

/// Owns the notch window and hosts the registered apps.
@MainActor
public final class NotchEngine {
    public let apps: [any NotchApp]

    private var model: NotchViewModel?
    private var panel: NotchPanel?
    private var settings: SettingsWindowController
    private var monitors: [Any] = []
    private var screenObserver: NSObjectProtocol?

    public init(apps: [any NotchApp]) {
        self.apps = apps
        self.settings = SettingsWindowController(apps: apps)
    }

    public func start() {
        guard let (_, geometry) = NotchGeometry.current() else { return }
        let model = NotchViewModel(apps: apps, geometry: geometry)
        self.model = model

        for app in apps {
            let appID = app.id
            let context = NotchContext(
                appID: appID,
                attention: { [weak self] attention in self?.model?.handleAttention(attention, from: appID) },
                openSettings: { [weak self] in self?.settings.show(appID: appID) }
            )
            app.activate(context: context)
        }

        let panel = NotchPanel(contentRect: .zero)
        let root = NotchRootView(model: model, openSettings: { [weak self] in self?.settings.show() })
        panel.contentView = FirstMouseHostingView(rootView: root)
        panel.ignoresMouseEvents = true
        self.panel = panel
        layoutPanel()
        panel.orderFrontRegardless()

        installMouseMonitors()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    public func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        apps.forEach { $0.deactivate() }
    }

    private func screensChanged() {
        guard let model, let (_, geometry) = NotchGeometry.current() else { return }
        model.geometry = geometry
        layoutPanel()
    }

    /// Pins the (fixed-size, mostly transparent) panel to the top of the screen, centered on the notch.
    private func layoutPanel() {
        guard let model, let panel else { return }
        panel.setFrame(model.geometry.rect(hanging: model.windowSize), display: true)
    }

    private func installMouseMonitors() {
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMouse() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handleMouse() }
            return event
        }) {
            monitors.append(local)
        }
    }

    private func handleMouse() {
        guard let model, let panel else { return }
        let point = NSEvent.mouseLocation
        model.mouseMoved(to: point)
        // Only capture clicks inside the visible notch shape; pass everything else through.
        panel.ignoresMouseEvents = !model.hitRect.contains(point)
    }
}
