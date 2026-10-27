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
    private var hotKey: HotKey?
    private var huds: SystemHUDs?
    private var dragTimer: Timer?
    /// The drag pasteboard's change count when the mouse button went down; a change means a new drag.
    private var dragChangeCount = 0
    private var mouseWasDown = false

    public init(apps: [any NotchApp]) {
        self.apps = apps
        self.settings = SettingsWindowController(apps: apps)
    }

    public func start() {
        notifications = NotificationRouter { [weak self] appID, payload in
            // An action button (Allow, Deny) is handled in the background; a click brings the app up.
            self?.deliver(NotchMessage(name: NotchMessage.notificationOpenedName, payload: payload), to: appID,
                          reveal: payload["action"] == nil)
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
                notify: { [weak self] title, body, payload, actions in
                    self?.notifications?.post(appID: appID, title: title, body: body, payload: payload, actions: actions)
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
        hotKey = HotKey { [weak self] in self?.toggleFromHotKey() }
        hotKey?.update()
        startWatchingFileDrags()
        huds = SystemHUDs { [weak self] transient in self?.showTransient(transient) }
        huds?.start()
        huds?.waitForAccessibility()
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
            MainActor.assumeIsolated {
                self?.rebuildNotches()
                self?.hotKey?.update()
            }
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
        // A nonactivating panel can take typing without making NotchMan the active app, so the app you were
        // in stays active and gets the keyboard back as soon as the notch closes.
        model.onWantsKeyboard = { [weak panel] in
            guard let panel, !panel.isKeyWindow else { return }
            panel.makeKey()
            panel.makeFirstResponder(panel.contentView)
        }
        model.onCollapse = { [weak panel] in
            guard let panel, panel.isKeyWindow else { return }
            panel.makeFirstResponder(nil)
            if NSApp.isActive {
                // One of NotchMan's own windows (Settings, a popped-out chat) had it; anything else is handled by
                // NotchFocus.restore once the notch is closed.
                NSApp.windows.first { $0 !== panel && $0.isVisible && $0.styleMask.contains(.titled) }?.makeKey()
            } else {
                panel.resignKey()
                NSWorkspace.shared.frontmostApplication?.activate()
            }
        }
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
        // Shared text shortcuts (⇧↩ = new line in multi-line fields) for every NotchMan window, then the notch's
        // own keys (⌘1–9, Esc, list navigation).
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            nonisolated(unsafe) let event = event
            let handled = MainActor.assumeIsolated { TextShortcuts.handle(event) || self?.handleKey(event) == true }
            return handled ? nil : event
        }) {
            monitors.append(keys)
        }
    }

    // MARK: - File drags

    /// Files dragged from anywhere (Finder, a browser, Mail) toward the notch open the app that takes them.
    /// Polls lightly while the button is down: other apps' drags don't reliably reach event monitors.
    private func startWatchingFileDrags() {
        guard apps.contains(where: \.acceptsFileDrags) else { return }
        dragTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkFileDrag() }
        }
    }

    private func checkFileDrag() {
        let down = NSEvent.pressedMouseButtons & 1 != 0
        let pasteboard = NSPasteboard(name: .drag)
        defer { mouseWasDown = down }
        if down && !mouseWasDown { dragChangeCount = pasteboard.changeCount }
        if !down {
            // Drag over: release the hold; the usual hover rules close the notch once the mouse leaves.
            if mouseWasDown { notches.values.forEach { $0.model.dragHeld = false } }
            return
        }
        guard pasteboard.changeCount != dragChangeCount,
              pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]),
              let target = apps.first(where: \.acceptsFileDrags) else { return }
        let point = NSEvent.mouseLocation
        for notch in notches.values where !notch.model.dragHeld {
            // Generous target: the notch plus a band below it.
            guard notch.model.contains(point, slack: 40) else { continue }
            notch.model.dragHeld = true
            notch.model.select(target.id)
            notch.model.expand()
            notch.panel.ignoresMouseEvents = false
        }
    }

    // MARK: - Keyboard

    /// The global hotkey opens the notch on the cursor's screen with the keyboard, or closes it again.
    private func toggleFromHotKey() {
        guard let model = attentionTarget, let notch = notches.values.first(where: { $0.model === model }) else { return }
        if model.state == .expanded && model.keyboardHeld {
            closeFromKeyboard(notch)
            return
        }
        model.keyboardHeld = true
        model.expand()
        NotchFocus.activateForTyping()
        notch.panel.makeKey()
        notch.panel.makeFirstResponder(notch.panel.contentView)
    }

    private func closeFromKeyboard(_ notch: ScreenNotch) {
        notch.model.collapse()
        notch.panel.makeFirstResponder(nil)
        notch.panel.resignKey()
        NotchFocus.restore()
    }

    /// ⌘1–9 switch apps; Esc closes; anything else goes to the selected app unless something is being typed.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard let panel = event.window as? NotchPanel,
              let notch = notches.values.first(where: { $0.panel === panel }),
              notch.model.state == .expanded else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers == .command, let digit = event.charactersIgnoringModifiers.flatMap(Int.init), (1...9).contains(digit) {
            guard digit <= apps.count else { return true }
            // Switching by keyboard: keep the notch open until Esc or a click outside, wherever the mouse is.
            notch.model.keyboardHeld = true
            notch.model.select(apps[digit - 1].id)
            return true
        }
        guard !Self.isTyping(panel.firstResponder) else { return false }
        if event.keyCode == 53 {  // Esc: the app may use it first (e.g. to drop a selection)
            if notch.model.selectedApp?.handleKey(event) != true { closeFromKeyboard(notch) }
            return true
        }
        return notch.model.selectedApp?.handleKey(event) ?? false
    }

    /// Text fields, terminals and web pages want every key themselves.
    static func isTyping(_ responder: NSResponder?) -> Bool {
        guard let responder else { return false }
        if responder is NSTextView { return true }
        var view = responder as? NSView
        while let current = view {
            let name = String(describing: type(of: current))
            if name.contains("Terminal") || name.hasPrefix("WK") { return true }
            view = current.superview
        }
        return false
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
            // While files are dragged to it, the notch keeps taking the drag (a mouse update mid-drag must not let
            // the drop fall through to the app behind).
            notch.panel.ignoresMouseEvents = !(notch.model.dragHeld || notch.model.contains(point))
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
