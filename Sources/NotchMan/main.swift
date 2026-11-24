import AppKit
import NotchEngine
import NotchMods

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var engine: NotchEngine?
    private var mods: ModLibrary?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Set up before launch finishes, so the notification click macOS launched this copy for comes here.
        if let running = SingleInstance.otherInstance() {
            isDuplicate = true
            SingleInstance.handOff(to: running)
        }
    }

    /// Another NotchMan was already running: this copy only passes a notification click to it, then quits.
    private var isDuplicate = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isDuplicate else { return }
        let engine = NotchEngine(apps: AppRegistry.makeApps())
        engine.extraPrompts = ModAuthoring.prompts
        engine.start()
        self.engine = engine
        // Notch apps Claude made: added to the dock after the built-in ones, kept in step with their folders.
        let mods = ModLibrary(add: { [weak engine] in engine?.add($0) },
                              remove: { [weak engine] in engine?.remove(appID: $0) },
                              reveal: { [weak engine] in engine?.reveal(appID: $0) })
        engine.commandProviders.append { [weak mods] query in mods?.commands(for: query) ?? .none }
        mods.start()
        self.mods = mods
        NSApp.mainMenu = MainMenu.make(openSettings: #selector(openSettings), target: self)
    }

    @objc private func openSettings() {
        engine?.showSettings()
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine?.stop()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
