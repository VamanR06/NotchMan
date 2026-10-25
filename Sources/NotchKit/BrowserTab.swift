import AppKit

/// The page open in the browser you were just using (Safari, Chrome, Arc, Brave, Edge), read over AppleScript.
/// macOS asks once per browser before NotchMan may read it.
public struct BrowserTab: Equatable, Sendable {
    public let url: URL
    public let title: String
    public let browser: String
    /// The browser's bundle id, to run scripts in the same tab later.
    public let bundleID: String
    /// Identifies the tab while it's open (Chromium's tab id; Safari's window id and tab index), so a tab that
    /// moves on from a page (Apply → the application form) can be recognized as the same tab.
    public let tabID: String?

    public init(url: URL, title: String, browser: String, bundleID: String = "", tabID: String? = nil) {
        self.url = url
        self.title = title
        self.browser = browser
        self.bundleID = bundleID
        self.tabID = tabID
    }

    public enum TabError: LocalizedError {
        case noBrowser, noTab, notAuthorized(String), javaScriptOff(String), script(String)

        public var errorDescription: String? {
            switch self {
            case .noBrowser: "Open the page in Safari, Chrome, Arc, Brave or Edge first."
            case .noTab: "No page is open in the browser."
            case .notAuthorized(let browser):
                "Allow NotchMan to control \(browser) in System Settings → Privacy & Security → Automation."
            case .javaScriptOff(let browser):
                browser == "Safari"
                    ? "In Safari, turn on Develop → Allow JavaScript from Apple Events (Develop shows after Settings → Advanced → Show features for web developers)."
                    : "In \(browser), turn on View → Developer → Allow JavaScript from Apple Events."
            case .script(let message):
                message
            }
        }
    }

    struct Browser {
        let bundleID: String
        let name: String
        /// Safari calls it "current tab" with a "name"; Chromium browsers "active tab" with a "title".
        let isSafari: Bool

        var script: String {
            let tab = isSafari ? "current tab of front window" : "active tab of front window"
            let title = isSafari ? "name" : "title"
            let tabID = isSafari
                ? "((id of front window) as text) & \":\" & ((index of current tab of front window) as text)"
                : "((id of active tab of front window) as text)"
            return """
            tell application id "\(bundleID)"
                if (count of windows) is 0 then return ""
                return (URL of \(tab)) & linefeed & \(tabID) & linefeed & (\(title) of \(tab))
            end tell
            """
        }
    }

    static let browsers = [
        Browser(bundleID: "com.apple.Safari", name: "Safari", isSafari: true),
        Browser(bundleID: "com.google.Chrome", name: "Chrome", isSafari: false),
        Browser(bundleID: "company.thebrowser.Browser", name: "Arc", isSafari: false),
        Browser(bundleID: "com.brave.Browser", name: "Brave", isSafari: false),
        Browser(bundleID: "com.microsoft.edgemac", name: "Edge", isSafari: false),
    ]

    @MainActor private static var lastBrowserID: String?
    @MainActor private static var observer: NSObjectProtocol?

    /// Starts remembering which browser was used last, so the notch (which is frontmost while you click in it)
    /// can still find "the browser you were in".
    @MainActor public static func startTracking() {
        guard observer == nil else { return }
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           browsers.contains(where: { $0.bundleID == front }) {
            lastBrowserID = front
        }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let id = app?.bundleIdentifier, browsers.contains(where: { $0.bundleID == id }) else { return }
            MainActor.assumeIsolated { lastBrowserID = id }
        }
    }

    /// The front tab of the frontmost browser, else of the browser used last, else of any running one.
    @MainActor public static func current() async throws -> BrowserTab {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let order = [front, lastBrowserID].compactMap { $0 } + browsers.map(\.bundleID)
        guard let id = order.first(where: { id in running.contains(id) && browsers.contains { $0.bundleID == id } }),
              let browser = browsers.first(where: { $0.bundleID == id }) else { throw TabError.noBrowser }

        let output: String
        do {
            output = try await runAppleScript(browser.script)
        } catch let error as ScriptError where error.notAuthorized {
            throw TabError.notAuthorized(browser.name)
        }
        let lines = output.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first, let url = URL(string: first), url.scheme?.hasPrefix("http") == true else {
            throw TabError.noTab
        }
        return BrowserTab(url: url, title: lines.count > 2 ? lines[2] : "", browser: browser.name, bundleID: browser.bundleID,
                          tabID: lines.count > 1 && !lines[1].isEmpty ? lines[1] : nil)
    }

    /// Opens `url` in this tab's browser (not the default browser), in a new tab.
    @MainActor public func openInSameBrowser(_ url: URL) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Whether the app in front is a supported browser (the notch never takes that over).
    @MainActor public static var frontmostIsBrowser: Bool {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        return browsers.contains { $0.bundleID == front }
    }

    /// Runs `javaScript` in this browser's front tab and returns its result as text. The script travels as an
    /// argument, never spliced into AppleScript source. Browsers only allow this once the user turns on
    /// "Allow JavaScript from Apple Events".
    public func runJavaScript(_ javaScript: String) async throws -> String {
        guard let browser = Self.browsers.first(where: { $0.bundleID == bundleID }) else { throw TabError.noBrowser }
        let source = browser.isSafari
            ? "on run argv\ntell application id \"\(bundleID)\" to do JavaScript (item 1 of argv) in current tab of front window\nend run"
            : "on run argv\ntell application id \"\(bundleID)\" to tell active tab of front window to execute javascript (item 1 of argv)\nend run"
        do {
            return try await Self.runAppleScript(source, arguments: [javaScript])
        } catch let error as ScriptError {
            if error.notAuthorized { throw TabError.notAuthorized(browser.name) }
            let lower = error.message.lowercased()
            if lower.contains("javascript") && (lower.contains("turned off") || lower.contains("allow javascript") || lower.contains("apple events")) {
                throw TabError.javaScriptOff(browser.name)
            }
            throw TabError.script(error.message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    struct ScriptError: Error {
        let message: String
        /// -1743: the user hasn't allowed (or declined) Automation for this app.
        var notAuthorized: Bool { message.contains("-1743") || message.contains("Not authorized") }
    }

    /// Runs in an `osascript` child process so a slow browser or the consent prompt never blocks the UI.
    private static func runAppleScript(_ source: String, arguments: [String] = []) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source] + arguments
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.terminationHandler = { process in
                let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if process.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    continuation.resume(throwing: ScriptError(message: message))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
}
