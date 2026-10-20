import AppKit
import NotchEngine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var engine: NotchEngine?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let engine = NotchEngine(apps: AppRegistry.makeApps())
        engine.start()
        self.engine = engine
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
