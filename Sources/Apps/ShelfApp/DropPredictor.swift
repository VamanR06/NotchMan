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

    /// 0…1 from what NotchMan knows itself: where this type went before, how recently the folder was used, and
    /// whether the file and folder names share a word ("Resume_2026.pdf" → "Resumes").
    static func localScore(files: [URL], candidate: DropCandidate, history: DropHistory) -> Double {
        guard !files.isEmpty else { return 0 }
        let historyShare = files.map { history.share(of: $0, in: candidate.url) }.reduce(0, +) / Double(files.count)
        let recency = candidate.recencyRank.map { 1 - Double($0) / Double(RecentFolders.limit) } ?? 0
        let folderWords = words(candidate.url.lastPathComponent)
        let named = files.contains { !words($0.deletingPathExtension().lastPathComponent).isDisjoint(with: folderWords) }
        return 0.5 * historyShare + 0.3 * recency + 0.2 * (named ? 1 : 0)
    }

    /// Lowercased words of 3+ letters, without a plural "s" ("Resumes" and "resume" match).
    static func words(_ name: String) -> Set<String> {
        let parts = name.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count >= 3 }
        return Set(parts.map { $0.count > 3 && $0.hasSuffix("s") ? String($0.dropLast()) : $0 })
    }

    /// Jev's say counts most once there is one; the local score breaks ties and carries your history.
    static func combined(local: Double, jev: Double?) -> Double {
        guard let jev else { return local }
        return 0.75 * jev + 0.25 * local
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

/// The top three folders for the files being dragged (or the shelved file you selected): local ranking at once,
/// refined by Jev a moment later when it's set up.
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
        guard JevSettings.isAvailable else { return }
        let request = DropRanking.request(files: files, candidates: candidates, history: history, context: context,
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
