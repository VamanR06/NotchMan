import Foundation

/// What Jev understood a typed request to mean: one of the apps' actions, with every parameter filled from its choices.
public struct CommandInterpretation: Equatable {
    public let actionID: String
    public let choices: [String: CommandChoice]
    /// The least sure of its decisions (the action, then each parameter).
    public let confidence: Double
}

/// The command bar's two halves: instant local search over what the apps offer, and Jev turning a request into an
/// action ("move the pdf I downloaded to resumes" → put_file(file: …, folder: …)).
public enum CommandRouting {
    // MARK: Local search

    /// How well `query` matches `item` (higher is better), or nil when some word doesn't match at all. Every word must
    /// match: a word start in the title counts most, then anywhere in the title, then the details, then the title's
    /// letters in order ("nmn" → "NotchMan").
    public static func score(_ query: String, item: CommandItem) -> Double? {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return nil }
        let title = item.title.lowercased()
        let titleWords = title.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let details = ([item.subtitle ?? "", item.kind] + item.keywords).joined(separator: " ").lowercased()
        var total = 0.0
        for word in words {
            if titleWords.contains(where: { $0.hasPrefix(word) }) { total += 3 }
            else if title.contains(word) { total += 2 }
            else if details.contains(word) { total += 1 }
            else if isSubsequence(word, of: title) { total += 0.5 }
            else { return nil }
        }
        // Shorter titles win ties: "Resumes" before "Resumes (old)".
        return total / Double(words.count) - Double(title.count) / 1000
    }

    public static func search(_ query: String, in items: [CommandItem], limit: Int = 8) -> [CommandItem] {
        var matches = items.compactMap { item in score(query, item: item).map { (item, $0) } }
        if matches.isEmpty {
            // A sentence ("move the resume i downloaded"): rank by how many of its meaningful words match.
            let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
                .filter { $0.count >= 3 && !stopWords.contains($0) }
            matches = items.compactMap { item in
                let scores = words.compactMap { score($0, item: item) }.filter { $0 >= 1 }
                return scores.isEmpty ? nil : (item, scores.reduce(0, +) / Double(max(words.count, 1)))
            }
        }
        return matches.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    static let stopWords: Set<String> = ["the", "and", "for", "from", "into", "with", "that", "this", "my", "its", "can",
                                         "you", "please", "open", "move", "put", "show", "find", "copy", "check",
                                         "off", "approve", "allow", "deny", "downloaded", "just", "file", "folder"]

    static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var rest = Substring(haystack)
        for character in needle {
            guard let index = rest.firstIndex(of: character) else { return false }
            rest = rest[rest.index(after: index)...]
        }
        return true
    }

    // MARK: Jev

    public static let toolQuestion = "__tool__"
    static let none = "none"
    /// Below these, the bar doesn't offer Jev's reading.
    public static let minActionProbability = 0.5
    public static let minChoiceProbability = 0.35

    /// The typed request goes out as text (redacted); every action and every choice is listed by an opaque key, so Jev
    /// picks among them and the real paths stay here. Parameters are asked for every action at once (they're cheap and
    /// independent), and only the chosen action's answers are used.
    @MainActor
    public static func request(query: String, actions: [CommandAction], context: IntentContext, redactor: Redactor)
        -> (state: JSONValue, questions: [String: JevQuestion], options: [String: [String: CommandChoice]]) {
        var toolOptions: [String: String] = [:]
        var questions: [String: JevQuestion] = [:]
        var options: [String: [String: CommandChoice]] = [:]
        for action in actions {
            toolOptions[action.id] = action.description
            for parameter in action.parameters where !parameter.choices.isEmpty {
                let id = "\(action.id).\(parameter.name)"
                var described: [String: String] = [none: "None of these; the request doesn't say which"]
                var keyed: [String: CommandChoice] = [:]
                for (index, choice) in parameter.choices.enumerated() {
                    let key = "o\(index + 1)"
                    keyed[key] = choice
                    described[key] = describe(choice, redactor: redactor)
                }
                options[id] = keyed
                questions[id] = .choice(
                    "If the user wants to \(lowercasedFirst(action.description)), which \(parameter.description) does "
                        + "their request in `request` mean?",
                    described)
            }
        }
        toolOptions[none] = "None of these: a question, a search, or something not listed"
        questions[toolQuestion] = .choice("What does the user want to do with the request in `request`?", toolOptions)
        let state: JSONValue = ["request": .string(redactor.text(query)), "context": context.json]
        return (state, questions, options)
    }

    /// The action Jev picked, with every parameter filled, if it's sure enough of all of them.
    public static func interpret(_ answers: [String: JevAnswer], actions: [CommandAction],
                                 options: [String: [String: CommandChoice]]) -> CommandInterpretation? {
        guard case .choice(let actionID, _, let probabilities)? = answers[toolQuestion], actionID != none,
              let action = actions.first(where: { $0.id == actionID }) else { return nil }
        var confidence = probabilities[actionID] ?? 0
        guard confidence >= minActionProbability else { return nil }
        var chosen: [String: CommandChoice] = [:]
        for parameter in action.parameters {
            let id = "\(action.id).\(parameter.name)"
            guard case .choice(let key, _, let probabilities)? = answers[id], key != none,
                  let choice = options[id]?[key] else { return nil }
            let probability = probabilities[key] ?? 0
            guard probability >= minChoiceProbability else { return nil }
            chosen[parameter.name] = choice
            confidence = min(confidence, probability)
        }
        return CommandInterpretation(actionID: action.id, choices: chosen, confidence: confidence)
    }

    @MainActor
    static func describe(_ choice: CommandChoice, redactor: Redactor) -> String {
        switch choice.kind {
        case .file:
            let name = redactor.text(choice.label, as: .fileName)
            return choice.path.map { "\(name) (in \(redactor.path(($0 as NSString).deletingLastPathComponent)))" } ?? name
        case .folder:
            return choice.path.map(redactor.path) ?? redactor.text(choice.label, as: .fileName)
        case .text:
            return redactor.text(choice.label)
        }
    }

    static func lowercasedFirst(_ text: String) -> String {
        text.prefix(1).lowercased() + text.dropFirst()
    }
}
