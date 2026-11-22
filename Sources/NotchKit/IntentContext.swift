import AppKit
import UniformTypeIdentifiers

/// What you're doing right now, as far as NotchMan can tell without asking: the app you're in and the time of day.
/// Apps add their own facts (the files being dragged, the folders on offer) when they ask Jev something.
public struct IntentContext: Equatable, Sendable {
    /// The app in front, e.g. "Safari" (where a drag most likely came from).
    public var frontmostApp: String?
    /// "weekday morning", "weekend evening", …
    public var timeOfDay: String

    public init(frontmostApp: String?, timeOfDay: String) {
        self.frontmostApp = frontmostApp
        self.timeOfDay = timeOfDay
    }

    @MainActor
    public static func current(now: Date = Date(), calendar: Calendar = .current) -> IntentContext {
        let front = NSWorkspace.shared.frontmostApplication
        let app = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front?.localizedName
        return IntentContext(frontmostApp: app, timeOfDay: timeOfDay(now, calendar: calendar))
    }

    public static func timeOfDay(_ date: Date, calendar: Calendar = .current) -> String {
        let hour = calendar.component(.hour, from: date)
        let part = switch hour {
        case 5..<12: "morning"
        case 12..<17: "afternoon"
        case 17..<22: "evening"
        default: "night"
        }
        return (calendar.isDateInWeekend(date) ? "weekend " : "weekday ") + part
    }

    public var json: JSONValue {
        var object: [String: JSONValue] = ["time": .string(timeOfDay)]
        if let frontmostApp { object["frontmost_app"] = .string(frontmostApp) }
        return .object(object)
    }

    /// A file described for Jev without its contents: name (redacted), kind and rough size.
    public static func describe(file url: URL, redactor: Redactor) -> JSONValue {
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey, .isDirectoryKey])
        var object: [String: JSONValue] = [
            "name": .string(redactor.text(url.lastPathComponent, as: .fileName)),
            "extension": .string(url.pathExtension.lowercased()),
        ]
        if values?.isDirectory == true { object["kind"] = "folder" }
        else if let type = values?.contentType { object["kind"] = .string(type.localizedDescription ?? type.identifier) }
        if let size = values?.fileSize { object["size"] = .string(sizeBucket(size)) }
        return .object(object)
    }

    public static func sizeBucket(_ bytes: Int) -> String {
        switch bytes {
        case ..<100_000: "under 100 KB"
        case ..<1_000_000: "under 1 MB"
        case ..<10_000_000: "1–10 MB"
        case ..<100_000_000: "10–100 MB"
        default: "over 100 MB"
        }
    }
}
