import Foundation
import NotchKit
import Observation
import os

/// A folder files could be dropped into.
struct DropCandidate: Equatable, Identifiable {
    enum Kind: String {
        case recent = "a folder you recently dropped files into"
        case project = "the folder of a Claude Code project you're working on"
        case place = "a standard folder"
        case folder = "a folder inside Documents or Desktop"
    }

    let url: URL
    let kind: Kind
    /// Among recent folders, 0 = most recent.
    var recencyRank: Int?

    var id: String { url.standardizedFileURL.path }
}

/// Where you've put files of each type before: extension → folder → count.
struct DropHistory: Equatable {
    static let key = "dropHistory"
    private(set) var counts: [String: [String: Int]] = [:]

    init(counts: [String: [String: Int]] = [:]) {
        self.counts = counts
    }

    static func load(_ defaults: UserDefaults?) -> DropHistory {
        DropHistory(counts: defaults?.dictionary(forKey: key) as? [String: [String: Int]] ?? [:])
    }

    func save(to defaults: UserDefaults?) {
        defaults?.set(counts, forKey: Self.key)
    }

    mutating func record(_ files: [URL], into folder: URL) {
        for file in files {
            counts[Self.type(of: file), default: [:]][folder.standardizedFileURL.path, default: 0] += 1
        }
    }

    /// Share (0…1) of past drops of this file's type that went to `folder`.
    func share(of file: URL, in folder: URL) -> Double {
        let byFolder = counts[Self.type(of: file)] ?? [:]
        let total = byFolder.values.reduce(0, +)
        guard total > 0 else { return 0 }
        return Double(byFolder[folder.standardizedFileURL.path] ?? 0) / Double(total)
    }

    func count(of file: URL, in folder: URL) -> Int {
        counts[Self.type(of: file)]?[folder.standardizedFileURL.path] ?? 0
    }

    static func type(of file: URL) -> String {
        let ext = file.pathExtension.lowercased()
        return ext.isEmpty ? (file.hasDirectoryPath ? "folder" : "none") : ext
    }
}

/// Ranking folders for dropped files: a local score from your history, recency and names, combined with Jev's
/// judgment when it's available.
enum DropRanking {
    static let maxCandidates = 30

    /// Recent folders, projects, places and the folders in Documents and Desktop, without repeats.
    static func candidates(recents: [URL], projects: [URL], places: [URL], extra: [URL]) -> [DropCandidate] {
        var seen = Set<String>()
        var result: [DropCandidate] = []
        func add(_ url: URL, _ kind: DropCandidate.Kind, rank: Int? = nil) {
            let candidate = DropCandidate(url: url, kind: kind, recencyRank: rank)
            guard result.count < maxCandidates, seen.insert(candidate.id).inserted else { return }
            result.append(candidate)
        }
        recents.enumerated().forEach { add($1, .recent, rank: $0) }
        projects.forEach { add($0, .project) }
        places.forEach { add($0, .place) }
        extra.forEach { add($0, .folder) }
        return result
    }

    /// 0…1 from what NotchMan knows itself: where this type went before, whether the file and folder names share
    /// words ("Resume_2026.pdf" → "Resumes"), and how recently the folder was used.
    static func localScore(files: [URL], candidate: DropCandidate, history: DropHistory) -> Double {
        guard !files.isEmpty else { return 0 }
        let historyShare = files.map { history.share(of: $0, in: candidate.url) }.reduce(0, +) / Double(files.count)
        let recency = candidate.recencyRank.map { 1 - Double($0) / Double(RecentFolders.limit) } ?? 0
        let folderWords = words(candidate.url.lastPathComponent)
        // Share of the folder's words the file's name has ("Offer Letter" fits "Offer Letters" better than "Cover Letters").
        let named = folderWords.isEmpty ? 0 : files.map {
            Double(words($0.deletingPathExtension().lastPathComponent).intersection(folderWords).count) / Double(folderWords.count)
        }.max() ?? 0
        return 0.45 * historyShare + 0.35 * named + 0.2 * recency
    }

    /// Lowercased words of 3+ letters, without a plural "s" ("Resumes" and "resume" match).
    static func words(_ name: String) -> Set<String> {
        let parts = name.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count >= 3 }
        return Set(parts.map { $0.count > 3 && $0.hasSuffix("s") ? String($0.dropLast()) : $0 })
    }

    /// Your own signals lead; Jev only nudges, mostly breaking ties between folders the rules can't tell apart.
    static func combined(local: Double, jev: Double?) -> Double {
        guard let jev else { return local }
        return 0.7 * local + 0.3 * jev
    }

    /// Jev is asked only for files of a type you've never filed (where your history has nothing to say), and only
    /// about the few folders the rules rank highest — not every folder on every drag.
    static let jevCandidates = 8

    static func needsJev(files: [URL], candidates: [DropCandidate], history: DropHistory) -> Bool {
        !candidates.contains { candidate in files.contains { history.share(of: $0, in: candidate.url) > 0 } }
    }

    static let levels = [
        "Clearly the wrong place for these files",
        "Unlikely, but possible",
        "A reasonable place for them",
        "Very likely where the user wants them",
    ]

    /// One request: the files, the context, and every candidate (as `c1…cN`, redacted), with one score question per
    /// candidate. Returns the key → candidate map to read the answers back.
    @MainActor
    static func request(files: [URL], candidates: [DropCandidate], history: DropHistory, context: IntentContext,
                        redactor: Redactor) -> (state: JSONValue, questions: [String: JevQuestion], keys: [String: DropCandidate]) {
        var described: [String: JSONValue] = [:]
        var questions: [String: JevQuestion] = [:]
        var keys: [String: DropCandidate] = [:]
        for (index, candidate) in candidates.enumerated() {
            let key = "c\(index + 1)"
            keys[key] = candidate
            var object: [String: JSONValue] = [
                "folder": .string(redactor.path(candidate.url.path)),
                "kind": .string(candidate.kind.rawValue),
            ]
            let past = files.map { history.count(of: $0, in: candidate.url) }.reduce(0, +)
            if past > 0 { object["past_drops_of_this_file_type"] = .number(Double(past)) }
            described[key] = .object(object)
            questions[key] = .score(
                "The user is dragging the files in `files` to drop them into a folder. How likely is it that they want "
                    + "them in the folder `candidates.\(key)`?",
                levels: levels)
        }
        let state: JSONValue = [
            "files": .array(files.prefix(10).map { IntentContext.describe(file: $0, redactor: redactor) }),
            "context": context.json,
            "candidates": .object(described),
        ]
        return (state, questions, keys)
    }
}

/// The top three folders for the files being dragged (or the shelved file you selected), ranked by where you've put
/// files like these, matching names and recency. For a file type you've never filed, Jev may nudge the order a moment
/// later when it's set up.
@MainActor @Observable
final class DropPredictor {
    struct Suggestion: Identifiable, Equatable {
        let candidate: DropCandidate
        let score: Double
        var id: String { candidate.id }
    }

    private(set) var suggestions: [Suggestion] = []
    /// The files the suggestions are for.
    private(set) var files: [URL] = []
    /// Jev is being asked.
    private(set) var isRefining = false
    /// Jev ranked the current suggestions (not just local rules).
    private(set) var usedJev = false

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "com.notchman", category: "drop-predictor")
    static let count = 3

    func predict(files: [URL], candidates: [DropCandidate], history: DropHistory, context: IntentContext) {
        guard !files.isEmpty, !candidates.isEmpty else { return clear() }
        if files == self.files, !suggestions.isEmpty { return }
        task?.cancel()
        self.files = files
        let local = Dictionary(uniqueKeysWithValues: candidates.map {
            ($0.id, DropRanking.localScore(files: files, candidate: $0, history: history))
        })
        suggestions = Self.top(candidates, scores: local)
        usedJev = false
        guard JevSettings.isAvailable, DropRanking.needsJev(files: files, candidates: candidates, history: history)
        else { return }
        let shortlist = Array(candidates.enumerated()
            .sorted { (local[$0.element.id] ?? 0, -$0.offset) > (local[$1.element.id] ?? 0, -$1.offset) }
            .prefix(DropRanking.jevCandidates).map(\.element))
        let request = DropRanking.request(files: files, candidates: shortlist, history: history, context: context,
                                          redactor: Jev.redactor())
        isRefining = true
        task = Task { [weak self] in
            defer { if !Task.isCancelled { self?.isRefining = false } }
            do {
                let answers = try await Jev.ask(state: request.state, questions: request.questions)
                guard !Task.isCancelled, let self, self.files == files else { return }
                var scores = local
                for (key, candidate) in request.keys {
                    scores[candidate.id] = DropRanking.combined(local: local[candidate.id] ?? 0,
                                                                jev: answers[key]?.normalized)
                }
                self.suggestions = Self.top(candidates, scores: scores)
                self.usedJev = true
            } catch {
                self?.log.notice("Jev ranking unavailable: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func clear() {
        task?.cancel()
        task = nil
        suggestions = []
        files = []
        isRefining = false
        usedJev = false
    }

    static func top(_ candidates: [DropCandidate], scores: [String: Double]) -> [Suggestion] {
        // Stable: equal scores keep the candidates' order (recent first).
        Array(candidates.enumerated()
            .sorted { (scores[$0.element.id] ?? 0, -$0.offset) > (scores[$1.element.id] ?? 0, -$1.offset) }
            .prefix(count)
            .map { Suggestion(candidate: $0.element, score: scores[$0.element.id] ?? 0) })
    }
}
