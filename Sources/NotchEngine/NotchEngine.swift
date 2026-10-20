import AppKit
import SwiftUI
import NotchKit

/// Owns the notch windows (one per display) and hosts the registered apps.
@MainActor
public final class NotchEngine {
    public let apps: [any NotchApp]

    /// When on, every display gets a notch (a virtual one where there's no hardware notch).
    static let allDisplaysKey = "showNotchOnAllDisplays"

    /// One notch window per display.
    private final class ScreenNotch {
        let model: NotchViewModel
        let panel: NotchPanel

        init(model: NotchViewModel, panel: NotchPanel) {
            self.model = model
            self.panel = panel
        }
    }

    private var notches: [CGDirectDisplayID: ScreenNotch] = [:]
    private var settings: SettingsWindowController
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []

    public init(apps: [any NotchApp]) {
        self.apps = apps
        self.settings = SettingsWindowController(apps: apps)
    }

    public func start() {
        for app in apps {
            let appID = app.id
            let context = NotchContext(
                appID: appID,
                attention: { [weak self] attention in self?.attentionTarget?.handleAttention(attention, from: appID) },
                openSettings: { [weak self] in self?.settings.show(appID: appID) }
            )
            app.activate(context: context)
        }

        rebuildNotches()
        installMouseMonitors()

        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildNotches() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildNotches() }
        })
    }

    public func showSettings() {
        settings.show()
    }

    public func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        apps.forEach { $0.deactivate() }
    }

    private var showsOnAllDisplays: Bool {
        UserDefaults.standard.object(forKey: Self.allDisplaysKey) as? Bool ?? true
    }

    /// Creates, updates or removes notch windows to match the connected displays.
    private func rebuildNotches() {
        let screens: [NSScreen]
        if showsOnAllDisplays {
            screens = NSScreen.screens
        } else {
            screens = NotchGeometry.current().map { [$0.0] } ?? []
        }

        var wanted: Set<CGDirectDisplayID> = []
        for screen in screens {
            guard let id = screen.displayID else { continue }
            wanted.insert(id)
            let geometry = NotchGeometry(screen: screen)
            if let existing = notches[id] {
                if existing.model.geometry != geometry {
                    existing.model.geometry = geometry
                    layout(existing)
                }
            } else {
                notches[id] = makeNotch(geometry: geometry)
            }
        }
        for (id, notch) in notches where !wanted.contains(id) {
            notch.panel.orderOut(nil)
            notches[id] = nil
        }
    }

    private func makeNotch(geometry: NotchGeometry) -> ScreenNotch {
        let model = NotchViewModel(apps: apps, geometry: geometry)
        let panel = NotchPanel(contentRect: .zero)
        let root = NotchRootView(model: model, openSettings: { [weak self] in self?.settings.show() })
        panel.contentView = FirstMouseHostingView(rootView: root)
        panel.ignoresMouseEvents = true
        let notch = ScreenNotch(model: model, panel: panel)
        layout(notch)
        panel.orderFrontRegardless()
        return notch
    }

    /// Pins the (fixed-size, mostly transparent) panel to the top of its screen, centered on the notch.
    private func layout(_ notch: ScreenNotch) {
        notch.panel.setFrame(notch.model.geometry.rect(hanging: notch.model.windowSize), display: true)
    }

    /// Attention goes to the notch on the display the cursor is on, else the hardware notch.
    private var attentionTarget: NotchViewModel? {
        let point = NSEvent.mouseLocation
        let models = notches.values.map(\.model)
        return models.first { $0.geometry.screenFrame.insetBy(dx: 0, dy: -1).contains(point) }
            ?? models.first { $0.geometry.hasNotch }
            ?? models.first
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
        let point = NSEvent.mouseLocation
        for notch in notches.values {
            notch.model.mouseMoved(to: point)
            // Only capture clicks inside the visible notch shape; pass everything else through.
            notch.panel.ignoresMouseEvents = !notch.model.contains(point)
            // A text field in the notch makes the panel key; once collapsed, hand the keyboard back
            // to the app the user was in so keystrokes don't go to the hidden panel.
            if notch.model.state == .collapsed, notch.panel.isKeyWindow, !NSApp.isActive {
                notch.panel.resignKey()
                NSWorkspace.shared.frontmostApplication?.activate()
            }
        }
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
