import Foundation
import Observation
import os

/// One judgment to ask Jev (TypeSafe's System One model): yes/no, one of a set, or a position on a scale.
public struct JevQuestion: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case noul
        /// Option name → what it means.
        case choice([String: String])
        /// Levels from low to high (2–10).
        case score([String])
    }

    public let kind: Kind
    public let instructions: String

    public static func noul(_ instructions: String) -> JevQuestion { JevQuestion(kind: .noul, instructions: instructions) }
    public static func choice(_ instructions: String, _ options: [String: String]) -> JevQuestion {
        JevQuestion(kind: .choice(options), instructions: instructions)
    }
    public static func score(_ instructions: String, levels: [String]) -> JevQuestion {
        JevQuestion(kind: .score(levels), instructions: instructions)
    }

    var json: JSONValue {
        switch kind {
        case .noul: ["type": "noul", "instructions": .string(instructions)]
        case .choice(let options):
            ["type": "choice", "instructions": .string(instructions), "criteria": .object(options.mapValues(JSONValue.string))]
        case .score(let levels):
            ["type": "score", "instructions": .string(instructions), "criteria": .array(levels.map(JSONValue.string))]
        }
    }
}

/// Jev's answer to one question.
public enum JevAnswer: Sendable, Equatable {
    /// Probability of yes.
    case noul(Double)
    case choice(String, confidence: Double, probabilities: [String: Double])
    /// `score` runs from 0 to `levels - 1`.
    case score(Double, confidence: Double, levels: Int)

    /// A score as 0…1, or a noul's probability: comparable across questions.
    public var normalized: Double? {
        switch self {
        case .noul(let probability): probability
        case .score(let score, _, let levels): levels > 1 ? score / Double(levels - 1) : nil
        case .choice: nil
        }
    }
}

public enum JevError: LocalizedError, Equatable {
    /// Turned off in Settings, or no API key.
    case unavailable
    /// Something personal was still in the request, so it wasn't sent.
    case blocked([String])
    case http(Int, String)
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .unavailable: "Jev is off or has no API key."
        case .blocked(let leaks): "Not sent: \(leaks.count) personal detail(s) were still in the request."
        case .http(let status, let detail): "Jev answered \(status): \(detail)"
        case .badResponse: "Jev's answer couldn't be read."
        }
    }
}

/// How much leaves the Mac.
public enum JevPrivacy: String, CaseIterable, Sendable {
    /// Nothing is sent; NotchMan uses its own rules.
    case off
    /// Personal details are replaced before sending, and a request that still has any isn't sent.
    case redacted
    /// Sent as is.
    case full

    public var label: String {
        switch self {
        case .off: "Off (local rules only)"
        case .redacted: "Redacted"
        case .full: "Full"
        }
    }
}

/// Settings and a network stand-in for one test, scoped to its task (so tests running at once can't see each other's).
public struct JevTestEnvironment: Sendable {
    public var privacy: JevPrivacy
    public var apiKey: String?
    public var identity: [String]
    public var transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public init(privacy: JevPrivacy, apiKey: String?, identity: [String],
                transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) {
        self.privacy = privacy
        self.apiKey = apiKey
        self.identity = identity
        self.transport = transport
    }

    @TaskLocal public static var current: JevTestEnvironment?
}

/// Jev's settings: the API key (Keychain), how much is sent, and your identity for redaction.
@MainActor
public enum JevSettings {
    static let keychain = Keychain(service: "com.notchman.jev")
    static let privacyKey = "jevPrivacy"
    static let identityKey = "jevIdentity"
    public static let model = "jev-latest"

    public static var apiKey: String? {
        get {
            if let test = JevTestEnvironment.current { return test.apiKey }
            return keychain.string(for: "apiKey").flatMap { $0.isEmpty ? nil : $0 }
        }
        set { keychain.set(newValue?.trimmingCharacters(in: .whitespacesAndNewlines), for: "apiKey") }
    }

    public static var privacy: JevPrivacy {
        get {
            JevTestEnvironment.current?.privacy
                ?? UserDefaults.standard.string(forKey: privacyKey).flatMap(JevPrivacy.init) ?? .redacted
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: privacyKey) }
    }

    /// Your name, email, username, … — never sent while redacting. Defaults to your account's name.
    public static var identity: [String] {
        get {
            JevTestEnvironment.current?.identity
                ?? UserDefaults.standard.stringArray(forKey: identityKey) ?? Redactor.defaultIdentity()
        }
        set { UserDefaults.standard.set(newValue.filter { !$0.isEmpty }, forKey: identityKey) }
    }

    public static var isAvailable: Bool { privacy != .off && apiKey != nil }
}

/// The last requests exactly as they left the Mac (and the ones held back), for Settings → "What was sent".
@MainActor @Observable
public final class JevLog {
    public struct Entry: Identifiable, Sendable {
        public let id = UUID()
        public let date: Date
        public let body: String
        /// "200 · 140 ms", "blocked: 2 details", "error: …"
        public let outcome: String
    }

    public static let shared = JevLog()
    public private(set) var entries: [Entry] = []

    func add(_ body: String, _ outcome: String) {
        entries.insert(Entry(date: Date(), body: body, outcome: outcome), at: 0)
        if entries.count > 50 { entries.removeLast(entries.count - 50) }
    }

    public func clear() { entries.removeAll() }
}

/// Asks Jev. Build the state with `Jev.redactor()` so personal details come out first; `ask` checks again before
/// anything is sent and refuses a request that still has some.
@MainActor
public enum Jev {
    nonisolated static let log = Logger(subsystem: "com.notchman", category: "jev")
    static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!

    /// Sends a request and returns the reply (a test's stand-in while one is set).
    static func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        if let test = JevTestEnvironment.current { return try await test.transport(request) }
        return try await URLSession.shared.data(for: request)
    }

    /// A redactor for one request, per the privacy setting (Full: one that changes nothing).
    public static func redactor() -> Redactor {
        Redactor(identity: JevSettings.identity, enabled: JevSettings.privacy != .full)
    }

    /// Asks every question about `state` in one request. Throws `.unavailable` when Jev is off or has no key, and
    /// `.blocked` when something personal is still in the request (it's logged, not sent).
    public static func ask(state: JSONValue, questions: [String: JevQuestion],
                           timeout: TimeInterval = 3) async throws -> [String: JevAnswer] {
        let privacy = JevSettings.privacy
        guard privacy != .off, let key = JevSettings.apiKey else { throw JevError.unavailable }
        let body: JSONValue = [
            "model": .string(JevSettings.model),
            "state": state,
            "questions": .object(questions.mapValues(\.json)),
        ]
        let data = try JSONEncoder.sorted.encode(body)
        let text = String(decoding: data, as: UTF8.self)
        if privacy == .redacted {
            let leaks = Redactor.leaks(in: body, identity: JevSettings.identity)
            guard leaks.isEmpty else {
                JevLog.shared.add(text, "held back: \(leaks.count) personal detail(s)")
                log.notice("Held back a request: \(leaks.count) personal details")
                throw JevError.blocked(leaks)
            }
        }
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let started = Date()
        do {
            let (reply, response) = try await send(request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            JevLog.shared.add(text, "\(status) · \(ms) ms")
            guard status == 200 else {
                throw JevError.http(status, String(decoding: reply.prefix(300), as: UTF8.self))
            }
            return try parse(reply, questions: questions)
        } catch let error as JevError {
            throw error
        } catch {
            JevLog.shared.add(text, "error: \(error.localizedDescription)")
            throw error
        }
    }

    nonisolated static func parse(_ data: Data, questions: [String: JevQuestion]) throws -> [String: JevAnswer] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = json["answers"] as? [String: [String: Any]] else { throw JevError.badResponse }
        var result: [String: JevAnswer] = [:]
        for (id, answer) in answers {
            let number = { (key: String) in (answer[key] as? NSNumber)?.doubleValue }
            let probabilities = (answer["probabilities"] as? [String: Any] ?? [:])
                .compactMapValues { ($0 as? NSNumber)?.doubleValue }
            switch answer["type"] as? String {
            case "noul":
                if let value = number("noul") { result[id] = .noul(value) }
            case "choice":
                if let choice = answer["choice"] as? String {
                    result[id] = .choice(choice, confidence: number("confidence") ?? 0, probabilities: probabilities)
                }
            case "score":
                guard let score = number("score") else { continue }
                var levels = probabilities.count
                if case .score(let asked) = questions[id]?.kind { levels = asked.count }
                result[id] = .score(score, confidence: number("confidence") ?? 0, levels: levels)
            default:
                continue
            }
        }
        return result
    }
}

extension JSONEncoder {
    /// Stable key order, so logged requests are easy to compare.
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
