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
    private var notifications: NotificationRouter?

    public init(apps: [any NotchApp]) {
        self.apps = apps
        self.settings = SettingsWindowController(apps: apps)
    }

    public func start() {
        notifications = NotificationRouter { [weak self] appID, payload in
            self?.deliver(NotchMessage(name: NotchMessage.notificationOpenedName, payload: payload), to: appID)
        }
        // "Ask ChatGPT / Claude / Muse" menus anywhere in the notch go to the Chat app.
        AskAI.shared.deliver = { [weak self] message in self?.deliver(message, to: "chat") }
        for app in apps {
            let appID = app.id
            let context = NotchContext(
                appID: appID,
                attention: { [weak self] attention in self?.attentionTarget?.handleAttention(attention, from: appID) },
                openSettings: { [weak self] in self?.settings.show(appID: appID) },
                send: { [weak self] message, target, reveal in self?.deliver(message, to: target, reveal: reveal) },
                isVisible: { [weak self] in
                    self?.notches.values.contains { $0.model.state == .expanded && $0.model.selectedAppID == appID } ?? false
                },
                notify: { [weak self] title, body, payload in
                    self?.notifications?.post(appID: appID, title: title, body: body, payload: payload)
                },
                holdOpen: { [weak self] hold in
                    self?.notches.values.forEach { notch in
                        if hold { notch.model.heldApps.insert(appID) } else { notch.model.heldApps.remove(appID) }
                    }
                },
                transient: { [weak self] transient in self?.showTransient(transient) }
            )
            app.activate(context: context)
        }

        rebuildNotches()
        installMouseMonitors()
        NotchFocus.startWatchingPopups { $0 is NotchPanel }

        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildNotches() }
        })
        // Keep the notch open while one of its menus is showing.
        for (name, open) in [(NSMenu.didBeginTrackingNotification, true), (NSMenu.didEndTrackingNotification, false)] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.notches.values.forEach { $0.model.isMenuOpen = open } }
            })
        }
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

    /// Briefly shows `transient` on the notch the cursor is on (system HUDs, finished downloads, …).
    func showTransient(_ transient: NotchTransient) {
        attentionTarget?.show(transient)
    }

    /// Switches the notch to `appID` first so its view is on screen (unless `reveal` is off), then hands it the
    /// message.
    private func deliver(_ message: NotchMessage, to appID: String, reveal: Bool = true) {
        guard let app = apps.first(where: { $0.id == appID }) else { return }
        if reveal, let model = attentionTarget {
            model.select(appID)
            if model.state == .collapsed { model.expand() }
        }
        app.receive(message)
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
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] event in
            // Global events go to other apps, i.e. happen outside the notch.
            let isClick = event.type == .leftMouseDown
            MainActor.assumeIsolated {
                self?.handleMouse()
                guard isClick else { return }
                let point = NSEvent.mouseLocation
                // Clicking macOS's password AutoFill / unlock prompt: give it the keyboard, keep the notch open.
                if self?.notches.values.contains(where: { $0.model.state == .expanded }) == true,
                   NotchFocus.handOffToSystemHelper(at: point) {
                    // The notch panel takes typing even while NotchMan isn't active, so it must give up the
                    // keyboard explicitly or keystrokes keep landing in the page behind the helper.
                    self?.notches.values.forEach { notch in
                        if notch.panel.isKeyWindow {
                            notch.panel.makeFirstResponder(nil)
                            notch.panel.resignKey()
                        }
                    }
                    return
                }
                self?.notches.values.forEach { $0.model.clickedOutside(at: point) }
            }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            let clickedNotch = event.type == .leftMouseDown && event.window is NotchPanel
            MainActor.assumeIsolated {
                self?.handleMouse()
                // Clicking back into the notch closes macOS's password AutoFill, like clicking back into an app.
                if clickedNotch { NotchFocus.dismissSystemHelpers() }
            }
            return event
        }) {
            monitors.append(local)
        }
        // Shared text shortcuts (⇧↩ = new line in multi-line fields) for every NotchMan window.
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            nonisolated(unsafe) let event = event
            let handled = MainActor.assumeIsolated { TextShortcuts.handle(event) }
            return handled ? nil : event
        }) {
            monitors.append(keys)
        }
    }

    private func handleMouse() {
        let point = NSEvent.mouseLocation
        // Over one of NotchMan's own pop-ups (password AutoFill, a menu or picker opened from the notch): treat
        // it as still being in the notch so it doesn't close underneath.
        let overOwnPopup = NSApp.windows.contains { window in
            window.isVisible && !(window is NotchPanel) && !window.styleMask.contains(.titled)
                && window.frame.contains(point)
        }
        for notch in notches.values {
            if !overOwnPopup { notch.model.mouseMoved(to: point) }
            // Only capture clicks inside the visible notch shape; pass everything else through.
            notch.panel.ignoresMouseEvents = !notch.model.contains(point)
            // A text field in the notch makes the panel key; once collapsed, hand the keyboard back
            // to the app the user was in so keystrokes don't go to the hidden panel.
            if notch.model.state == .collapsed, notch.panel.isKeyWindow, !NSApp.isActive {
                notch.panel.resignKey()
                NSWorkspace.shared.frontmostApplication?.activate()
            }
        }
        // Typing in a web page activated NotchMan; once every notch has closed, give focus back.
        if notches.values.allSatisfy({ $0.model.state == .collapsed }) {
            NotchFocus.restore()
        }
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
