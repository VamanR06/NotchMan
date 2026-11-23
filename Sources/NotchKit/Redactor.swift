import Foundation
import NaturalLanguage

/// Takes personal details out of text before it leaves the Mac (for Jev), on-device. Details become typed
/// placeholders that keep their meaning — `Vaman_Resume.pdf` → `MY_NAME_Resume.pdf`, `jane@x.com` → `EMAIL_1` — and
/// stay the same within one request, so Jev can still tell two mentions are the same thing.
///
/// Make one per request: the placeholder numbering lives in it.
public final class Redactor {
    /// What kind of string is being redacted; each gets the rules that keep it useful.
    public enum Field {
        /// Free text (a page title, a calendar event): names, places, organizations, contact details, numbers.
        case text
        /// A file or folder name: personal names and contact details, but not places or organizations ("GitHub",
        /// "Google Drive" are what a folder is for, not who you are).
        case fileName
    }

    /// Your own name, email, username, … (each matched case-insensitively, also run together or split by `_-.`).
    public let identity: [String]
    /// Off (privacy set to Full): everything passes through unchanged.
    public let isEnabled: Bool
    private var placeholders: [String: String] = [:]
    private var counts: [String: Int] = [:]

    public init(identity: [String], enabled: Bool = true) {
        self.identity = Self.expand(identity)
        isEnabled = enabled
    }

    // MARK: Fields

    public func text(_ string: String, as field: Field = .text) -> String {
        guard isEnabled else { return string }
        var result = string
        result = replace(Self.secret, in: result) { self.placeholder("SECRET", for: $0) }
        result = replace(Self.email, in: result) { match in
            self.isIdentity(match) ? "MY_EMAIL" : self.placeholder("EMAIL", for: match)
        }
        result = replace(Self.cardNumber, in: result) { match in
            Self.passesLuhn(match) ? self.placeholder("NUMBER", for: match) : match
        }
        result = replace(Self.idNumber, in: result) { self.placeholder("NUMBER", for: $0) }
        result = replace(Self.iban, in: result) { self.placeholder("NUMBER", for: $0) }
        result = detect(.phoneNumber, in: result) { self.placeholder("PHONE", for: $0) }
        if field == .text {
            result = detect(.address, in: result) { self.placeholder("ADDRESS", for: $0) }
            result = detect(.link, in: result) { Self.urlShape($0) }
        }
        result = replaceIdentity(in: result)
        result = replaceNames(in: result, includePlacesAndOrganizations: field == .text)
        return result
    }

    /// A path: your home folder becomes `~`, and each part is redacted as a file name.
    public func path(_ path: String) -> String {
        guard isEnabled else { return path }
        let home = NSHomeDirectory()
        var shortened = path
        if path == home { shortened = "~" } else if path.hasPrefix(home + "/") { shortened = "~" + path.dropFirst(home.count) }
        return shortened.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0 == "~" ? "~" : text(String($0), as: .fileName) }
            .joined(separator: "/")
    }

    /// A web address cut to its site and the shape of its path: `https://boards.greenhouse.io/acme/jobs/123?gh_src=x`
    /// → `boards.greenhouse.io/acme/jobs/<id>`.
    public func url(_ string: String) -> String {
        isEnabled ? replaceIdentity(in: Self.urlShape(string)) : string
    }

    // MARK: Final check

    /// What in `value` still looks personal: anything in `identity`, or an email, phone, card or ID number, or key.
    /// Empty when it's safe to send.
    public static func leaks(in value: JSONValue, identity: [String]) -> [String] {
        let terms = expand(identity).map { ($0.lowercased(), wholeWord($0)) }
        var found: [String] = []
        _ = value.mapStrings { string in
            found += terms.filter { !matches(of: $0.1, in: string).isEmpty }.map(\.0)
            for pattern in [email, secret, idNumber, iban] {
                found += matches(of: pattern, in: string)
            }
            found += matches(of: cardNumber, in: string).filter(passesLuhn)
            if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue) {
                let range = NSRange(string.startIndex..., in: string)
                found += detector.matches(in: string, range: range).compactMap { Range($0.range, in: string).map { String(string[$0]) } }
            }
            return string
        }
        return found
    }

    /// The defaults for "my identity": your full name's parts and your account name.
    public static func defaultIdentity() -> [String] {
        let parts = NSFullUserName().split(whereSeparator: { $0 == " " }).map(String.init)
        return parts + [NSUserName()]
    }

    // MARK: - Internals

    private func placeholder(_ kind: String, for original: String) -> String {
        let key = kind + "|" + original.lowercased()
        if let existing = placeholders[key] { return existing }
        counts[kind, default: 0] += 1
        let made = "\(kind)_\(counts[kind]!)"
        placeholders[key] = made
        return made
    }

    private func isIdentity(_ string: String) -> Bool {
        let lower = string.lowercased()
        return identity.contains { lower.contains($0.lowercased()) }
    }

    /// Your own details, longest first so a full name goes before its parts.
    private func replaceIdentity(in string: String) -> String {
        var result = string
        for term in identity.sorted(by: { $0.count > $1.count }) {
            let label = term.contains("@") ? "MY_EMAIL" : (term.lowercased() == NSUserName().lowercased() ? "MY_USERNAME" : "MY_NAME")
            result = replace(Self.wholeWord(term), in: result) { _ in label }
        }
        return result
    }

    /// People (and in free text places and organizations) that `NLTagger` recognizes. File names are tagged with
    /// `_-.` read as spaces (one character for one, so the ranges line up with the original).
    private func replaceNames(in string: String, includePlacesAndOrganizations: Bool) -> String {
        let spaced = String(string.map { "_-.".contains($0) ? " " : $0 })
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = spaced
        var found: [(Range<String.Index>, String)] = []
        tagger.enumerateTags(in: spaced.startIndex..<spaced.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            let kind: String? = switch tag {
            case .personalName: "PERSON"
            case .placeName where includePlacesAndOrganizations: "PLACE"
            case .organizationName where includePlacesAndOrganizations: "ORG"
            default: nil
            }
            let word = String(spaced[range])
            // Placeholders already put in (MY_NAME, EMAIL_1, …) are all caps; leave them.
            if let kind, word != word.uppercased() { found.append((range, kind)) }
            return true
        }
        var result = string
        for (range, kind) in found.reversed() {
            let lower = range.lowerBound.utf16Offset(in: spaced), upper = range.upperBound.utf16Offset(in: spaced)
            let start = result.utf16.index(result.startIndex, offsetBy: lower)
            let end = result.utf16.index(result.startIndex, offsetBy: upper)
            result.replaceSubrange(start..<end, with: placeholder(kind, for: String(result[start..<end])))
        }
        return result
    }

    private func replace(_ pattern: NSRegularExpression, in string: String, with transform: (String) -> String) -> String {
        var result = string
        let range = NSRange(string.startIndex..., in: string)
        for match in pattern.matches(in: string, range: range).reversed() {
            guard let found = Range(match.range, in: result) else { continue }
            result.replaceSubrange(found, with: transform(String(result[found])))
        }
        return result
    }

    private func detect(_ type: NSTextCheckingResult.CheckingType, in string: String,
                        with transform: (String) -> String) -> String {
        guard let detector = try? NSDataDetector(types: type.rawValue) else { return string }
        var result = string
        for match in detector.matches(in: string, range: NSRange(string.startIndex..., in: string)).reversed() {
            guard let found = Range(match.range, in: result) else { continue }
            let original = String(result[found])
            if original.contains("_") && original == original.uppercased() { continue }  // a placeholder
            result.replaceSubrange(found, with: transform(original))
        }
        return result
    }

    static func urlShape(_ string: String) -> String {
        guard let components = URLComponents(string: string.contains("://") ? string : "https://" + string),
              let host = components.host else { return string }
        let parts = components.path.split(separator: "/").map { part -> String in
            let segment = String(part)
            let digits = segment.filter(\.isNumber).count
            let looksLikeID = digits >= 4 || segment.count >= 24 || UUID(uuidString: segment) != nil
            return looksLikeID ? "<id>" : segment
        }
        return ([host] + parts).joined(separator: "/")
    }

    /// `jane` also as `Jane`, and `Jane Doe` also as `janedoe`, `jane_doe`, `jane.doe`, `jane-doe`.
    static func expand(_ terms: [String]) -> [String] {
        var result: [String] = []
        for term in terms.map({ $0.trimmingCharacters(in: .whitespaces) }) where term.count >= 3 {
            result.append(term)
            let words = term.split(separator: " ").map(String.init)
            if words.count > 1 {
                result += ["", "_", ".", "-"].map { words.joined(separator: $0) }
                result += words.filter { $0.count >= 3 }
            }
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0.lowercased()).inserted }
    }

    /// `term` as a whole word, ignoring case: not inside another word ("Doe" isn't in "Does"), but `_-./` and digits
    /// count as breaks, so it's found in `Jane_Doe_Resume.pdf`.
    static func wholeWord(_ term: String) -> NSRegularExpression {
        let escaped = NSRegularExpression.escapedPattern(for: term)
        // A valid pattern built from an escaped literal.
        return try! NSRegularExpression(pattern: #"(?<!\p{L})"# + escaped + #"(?!\p{L})"#, options: [.caseInsensitive])
    }

    private static func matches(of pattern: NSRegularExpression, in string: String) -> [String] {
        pattern.matches(in: string, range: NSRange(string.startIndex..., in: string))
            .compactMap { Range($0.range, in: string).map { String(string[$0]) } }
    }

    static func passesLuhn(_ number: String) -> Bool {
        let digits = number.compactMap(\.wholeNumberValue)
        guard (13...19).contains(digits.count) else { return false }
        let sum = digits.reversed().enumerated().reduce(0) { total, pair in
            let (index, digit) = pair
            guard index % 2 == 1 else { return total + digit }
            let doubled = digit * 2
            return total + (doubled > 9 ? doubled - 9 : doubled)
        }
        return sum % 10 == 0
    }

    // swiftlint:disable force_try
    nonisolated(unsafe) static let email = try! NSRegularExpression(
        pattern: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#)
    nonisolated(unsafe) static let cardNumber = try! NSRegularExpression(pattern: #"\b(?:\d[ -]?){12,18}\d\b"#)
    /// US Social Security numbers.
    nonisolated(unsafe) static let idNumber = try! NSRegularExpression(pattern: #"\b\d{3}-\d{2}-\d{4}\b"#)
    nonisolated(unsafe) static let iban = try! NSRegularExpression(pattern: #"\b[A-Z]{2}\d{2}(?:[ ]?[A-Z0-9]{4}){3,7}\b"#)
    /// API keys and tokens: well-known prefixes, or a long run of key characters.
    nonisolated(unsafe) static let secret = try! NSRegularExpression(
        pattern: #"\b(?:sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|xox[abpr]-[A-Za-z0-9-]{10,}|[A-Za-z0-9_\-]{40,})\b"#)
    // swiftlint:enable force_try
}
