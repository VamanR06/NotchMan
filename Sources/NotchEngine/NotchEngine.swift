import AppKit
import os
import SwiftUI
import WebKit
import NotchKit

/// Owns the notch windows (one per display) and hosts the registered apps.
@MainActor
public final class NotchEngine {
    /// The apps in the dock, in order. Generated notch apps are added and removed while NotchMan runs.
    public private(set) var apps: [any NotchApp]
    /// More things the command bar can find and do, besides the apps' own (e.g. making a new notch app).
    public var commandProviders: [@MainActor (String) -> NotchCommands] = []

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
    static let log = Logger(subsystem: "com.notchman", category: "engine")
    /// One command bar, shown on whichever notch opened it.
    let commandBar = CommandBarModel()
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
        commandBar.commands = { [weak self] query in self?.commands(for: query) ?? .none }
        commandBar.onRun = { [weak self] appID in self?.commandRan(revealing: appID) }
        notifications = NotificationRouter { [weak self] appID, payload in
            // An action button (Allow, Deny) is handled in the background; a click brings the app up.
            self?.deliver(NotchMessage(name: NotchMessage.notificationOpenedName, payload: payload), to: appID,
                          reveal: payload["action"] == nil)
        }
        // "Ask ChatGPT / Claude / Muse" menus anywhere in the notch go to the Chat app.
        AskAI.shared.deliver = { [weak self] message in self?.deliver(message, to: "chat") }
        apps.forEach(activate)

        rebuildNotches()
        installMouseMonitors()
        hotKey = HotKey { [weak self] in self?.toggleFromHotKey() }
        hotKey?.update()
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
        // File pickers and alerts opened from the notch go above it; at their usual level they'd open underneath.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { note in
            nonisolated(unsafe) let object = note.object
            MainActor.assumeIsolated {
                guard let window = object as? NSWindow, Self.isDialog(window) else { return }
                window.level = NotchPanel.aboveNotch
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.rebuildNotches()
                self?.hotKey?.update()
            }
        })
    }


    /// Starts an app with its context (storage, notifications, messages to other apps, …).
    private func activate(_ app: any NotchApp) {
        let appID = app.id
        let context = NotchContext(
            appID: appID,
            attention: { [weak self] attention in self?.attentionTarget?.handleAttention(attention, from: appID) },
            openSettings: { [weak self] in self?.showSettings(appID: appID) },
            send: { [weak self] message, target, reveal in self?.deliver(message, to: target, reveal: reveal) },
            isVisible: { [weak self] in
                self?.notches.values.contains { $0.model.state == .expanded && $0.model.selectedAppID == appID } ?? false
            },
            notify: { [weak self] notification in self?.notifications?.post(appID: appID, notification) },
            withdrawNotification: { [weak self] id in self?.notifications?.withdraw(appID: appID, id: id) },
            holdOpen: { [weak self] hold in
                self?.notches.values.forEach { notch in
                    if hold { notch.model.heldApps.insert(appID) } else { notch.model.heldApps.remove(appID) }
                }
            },
            transient: { [weak self] transient in self?.showTransient(transient) }
        )
        app.activate(context: context)
    }

    /// Adds an app to the end of the dock (a generated notch app), started and ready.
    public func add(_ app: any NotchApp) {
        guard !apps.contains(where: { $0.id == app.id }) else { return }
        activate(app)
        apps.append(app)
        appsChanged()
    }

    /// Takes an app out of the dock and stops it.
    public func remove(appID: String) {
        guard let index = apps.firstIndex(where: { $0.id == appID }) else { return }
        apps.remove(at: index).deactivate()
        appsChanged()
    }

    /// Shows `appID` in the notch on the cursor's screen, opening it if needed.
    public func reveal(appID: String) {
        guard let model = attentionTarget, apps.contains(where: { $0.id == appID }) else { return }
        model.select(appID)
        if model.state == .collapsed { model.expand() }
    }

    private func appsChanged() {
        for notch in notches.values {
            notch.model.apps = apps
            layout(notch)
        }
    }

    /// Opens Settings and closes the notch, which would otherwise cover the window (it floats above the menu bar).
    public func showSettings(appID: String? = nil) {
        settings.show(appID: appID)
        notches.values.filter { $0.model.state == .expanded }.forEach { $0.model.collapse() }
    }

    /// An open/save panel or a modal alert.
    static func isDialog(_ window: NSWindow) -> Bool {
        guard !(window is NotchPanel) else { return false }
        return window is NSSavePanel || NSApp.modalWindow === window || window.level == .modalPanel
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
        let root = NotchRootView(model: model, commandBar: commandBar,
                                 openSettings: { [weak self] in self?.showSettings() },
                                 openCommandBar: { [weak self, weak model] in
                                     guard let self, let model else { return }
                                     self.openCommandBar(on: model)
                                 },
                                 closeCommandBar: { [weak self, weak model] in
                                     guard let self, let model else { return }
                                     self.closeCommandBar(on: model)
                                 })
        panel.contentView = FirstMouseHostingView(rootView: root)
        panel.ignoresMouseEvents = true
        let notch = ScreenNotch(model: model, panel: panel)
        model.chooseOpening = { [weak self] current in await self?.chooseOpening(current: current) }
        // A nonactivating panel can take typing without making NotchMan the active app, so the app you were
        // in stays active and gets the keyboard back as soon as the notch closes. Hovering makes it key, as do a
        // click inside (AppKit) and the hotkey; either way the model hears about it here.
        model.onWantsKeyboard = { [weak panel] in
            guard let panel, !panel.isKeyWindow else { return }
            panel.makeKey()
            panel.makeFirstResponder(panel.contentView)
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: panel, queue: .main) { [weak model] _ in
            MainActor.assumeIsolated {
                guard let model, model.state == .expanded, !model.tookKeyboard else { return }
                model.keyboardTaken()
                NotchFocus.notchTookKeyboard()
            }
        })
        model.onCollapse = { [weak panel] in
            guard let panel, panel.isKeyWindow else { return }
            panel.makeFirstResponder(nil)
            panel.resignKey()
            if !NSApp.isActive {
                // The panel took typing without activating NotchMan; the app you were in is still active.
                NSWorkspace.shared.frontmostApplication?.activate()
            }
            NotchFocus.restore()
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
                self?.watchFileDragsWhileMouseDown()
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
                // A click the app behind got although it landed on the open notch: the panel was letting clicks
                // through. Shouldn't happen; log it to find out why, and make the panel take clicks again.
                for notch in self?.notches.values ?? [:].values where notch.model.state == .expanded && notch.model.contains(point) {
                    Self.log.error("Click passed through the open notch (ignoresMouseEvents=\(notch.panel.ignoresMouseEvents, privacy: .public), key=\(notch.panel.isKeyWindow, privacy: .public))")
                    notch.panel.ignoresMouseEvents = false
                }
                self?.notches.values.forEach { $0.model.clickedOutside(at: point) }
            }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            let isClick = event.type == .leftMouseDown
            let clickedNotch = isClick && event.window is NotchPanel
            MainActor.assumeIsolated {
                self?.handleMouse()
                if isClick { self?.watchFileDragsWhileMouseDown() }
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
            let handled = MainActor.assumeIsolated {
                // Typing in the notch (a field, a list, a terminal) holds it open until Esc or a click outside.
                if let panel = event.window as? NotchPanel {
                    self?.notches.values.first { $0.panel === panel }?.model.userTyped()
                }
                return TextShortcuts.handle(event) || self?.handleKey(event) == true
            }
            return handled ? nil : event
        }) {
            monitors.append(keys)
        }
    }

    // MARK: - File drags

    /// Files dragged from anywhere (Finder, a browser, Mail) toward the notch open the app that takes them.
    /// Polls lightly while the button is down (other apps' drags don't reliably reach event monitors): a mouse-down
    /// starts it and it stops once the button is up, so an idle Mac isn't woken ten times a second.
    private func watchFileDragsWhileMouseDown() {
        guard dragTimer == nil, apps.contains(where: \.acceptsFileDrags) else { return }
        checkFileDrag()  // notes what's on the drag pasteboard before this press
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
            dragTimer?.invalidate()
            dragTimer = nil
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
            let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
            target.fileDragEntered(urls ?? [])
        }
    }

    // MARK: - Keyboard

    /// The global hotkey opens the notch on the cursor's screen with the keyboard, or closes it again.
    /// The hotkey is the command bar's, like Spotlight: it opens the notch with the bar (or adds the bar to a notch
    /// you hovered open), and pressed again closes the bar — and the notch too, if the hotkey opened it.
    private func toggleFromHotKey() {
        guard let model = attentionTarget, let notch = notches.values.first(where: { $0.model === model }) else { return }
        switch Self.hotKeyAction(state: model.state, barShown: model.isCommandBarShown) {
        case .close:
            closeCommandBar(on: model)
        case .addBar:
            notch.panel.makeKey()
            openCommandBar(on: model)
        case .open:
            model.expand()
            model.barOpenedNotch = true
            NotchFocus.activateForTyping()
            notch.panel.makeKey()
            notch.panel.makeFirstResponder(notch.panel.contentView)
            openCommandBar(on: model)
        }
    }

    enum HotKeyAction: Equatable {
        /// Open the notch with the bar.
        case open
        /// The notch is open (hovered): show the bar in it.
        case addBar
        /// Close the bar (and the notch, if the hotkey opened it).
        case close
    }

    static func hotKeyAction(state: NotchViewModel.State, barShown: Bool) -> HotKeyAction {
        if state == .collapsed { return .open }
        return barShown ? .close : .addBar
    }

    // MARK: - Opening to what's relevant

    /// The app a hover opening should show instead of `current`, if any (see `OpeningChooser`).
    func chooseOpening(current: String) async -> String? {
        guard UserDefaults.standard.object(forKey: OpeningChooser.enabledKey) as? Bool ?? true else { return nil }
        let states = apps.map { OpeningChooser.AppState(id: $0.id, name: $0.name, relevance: $0.relevance) }
        return OpeningChooser.pick(apps: states, current: current)
    }

    // MARK: - Command bar

    func openCommandBar(on model: NotchViewModel) {
        commandBar.reset()
        // Typing in it keeps the notch open until Esc or a click outside, wherever the mouse goes.
        model.keyboardHeld = true
        model.isLauncherOpen = false
        withAnimation(.easeOut(duration: 0.12)) { model.isCommandBarShown = true }
    }

    /// Esc in an empty bar: back to the app underneath, with the keyboard.
    /// Esc in an empty bar, or the hotkey again: if the hotkey opened the notch just for the bar, close the notch;
    /// else go back to the app underneath, with the keyboard.
    func closeCommandBar(on model: NotchViewModel) {
        guard let notch = notches.values.first(where: { $0.model === model }) else { return }
        if model.barOpenedNotch {
            closeFromKeyboard(notch)
            return
        }
        withAnimation(.easeOut(duration: 0.12)) { model.isCommandBarShown = false }
        // Back to an ordinary hover: moving away closes the notch again.
        model.keyboardHeld = false
        notch.panel.makeFirstResponder(notch.panel.contentView)
    }

    /// Everything the apps offer for `query`, plus each app itself (to switch to it).
    func commands(for query: String) -> NotchCommands {
        var all = NotchCommands()
        for provider in commandProviders {
            let offered = provider(query)
            all.items += offered.items
            all.actions += offered.actions
            all.fallbacks += offered.fallbacks
        }
        for app in apps {
            let offered = app.commands(for: query)
            all.items += offered.items
            all.actions += offered.actions
            all.fallbacks += offered.fallbacks
            all.items.append(CommandItem(id: "app." + app.id, title: app.name, symbol: app.iconSystemName, kind: "App",
                                         revealsApp: app.id, run: {}))
        }
        return all
    }

    /// A command ran: show the app it belongs to, or close the notch (it opened something elsewhere).
    private func commandRan(revealing appID: String?) {
        guard let notch = notches.values.first(where: { $0.model.isCommandBarShown }) else { return }
        if let appID {
            notch.model.select(appID)
            notch.panel.makeFirstResponder(notch.panel.contentView)
        } else {
            closeFromKeyboard(notch)
        }
    }

    private func closeFromKeyboard(_ notch: ScreenNotch) {
        notch.model.collapse()
        notch.panel.makeFirstResponder(nil)
        notch.panel.resignKey()
        NotchFocus.restore()
    }

    /// ⌘1–9 switch apps; Esc closes All Apps, then the notch; anything else goes to the selected app unless something is being typed.
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
        if event.keyCode == 53, notch.model.isLauncherOpen {  // Esc closes All Apps before the notch
            notch.model.toggleLauncher()
            return true
        }
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
            if current is NotchTypingView || current is WKWebView { return true }
            view = current.superview
        }
        return false
    }

    private func handleMouse() {
        let point = NSEvent.mouseLocation
        // Over one of NotchMan's own pop-ups (password AutoFill, a menu, a file picker or alert opened from the notch):
        // treat it as still being in the notch so it doesn't close underneath.
        let overOwnPopup = NSApp.windows.contains { window in
            window.isVisible && !(window is NotchPanel) && (!window.styleMask.contains(.titled) || Self.isDialog(window))
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
