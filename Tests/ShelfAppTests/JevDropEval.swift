import Foundation
import Testing
@testable import NotchKit
@testable import ShelfApp

/// How well the Shelf's suggestions pick the folder you meant, on 30 typical drags: local rules alone vs. with Jev.
/// Calls the real service, so it only runs with a key:
///
///     JEV_API_KEY=sk-… swift test --filter JevDropEval
///
/// Requests are redacted as in the app (identity "Jane Doe"); files and folders are made up, nothing is read from disk.
@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["JEV_API_KEY"] != nil))
struct JevDropEval {
    struct Case {
        let file: String
        let app: String?
        let expected: String
    }

    static let home = NSHomeDirectory()
    /// The same folders on offer for every drag, like a real Shelf: recent folders first.
    static let folders: [(path: String, kind: DropCandidate.Kind)] = [
        ("GitHub/NotchMan", .recent), ("Documents/Taxes/2026", .recent), ("Desktop/Screenshots", .recent),
        ("GitHub/JobManager", .project), ("GitHub/NotchMan", .project),
        ("Desktop", .place), ("Documents", .place), ("Downloads", .place),
        ("Documents/Resumes", .folder), ("Documents/Cover Letters", .folder), ("Documents/Receipts", .folder),
        ("Documents/School/EECS 482", .folder), ("Documents/School/Math 217", .folder), ("Documents/Photos", .folder),
        ("Documents/Music", .folder), ("Documents/Travel", .folder), ("Documents/Housing", .folder),
        ("Desktop/Design Assets", .folder), ("Documents/Medical", .folder), ("Documents/Offer Letters", .folder),
    ]

    static let cases: [Case] = [
        Case(file: "Jane_Doe_Resume_2026.pdf", app: "Safari", expected: "Documents/Resumes"),
        Case(file: "resume-v7-final.docx", app: "Mail", expected: "Documents/Resumes"),
        Case(file: "Cover Letter - Stripe.pdf", app: "Pages", expected: "Documents/Cover Letters"),
        Case(file: "cover_letter_anthropic.docx", app: "Word", expected: "Documents/Cover Letters"),
        Case(file: "W2_2026_Employer.pdf", app: "Safari", expected: "Documents/Taxes/2026"),
        Case(file: "1099-INT Chase.pdf", app: "Safari", expected: "Documents/Taxes/2026"),
        Case(file: "Screenshot 2026-11-22 at 10.15.03.png", app: "Finder", expected: "Desktop/Screenshots"),
        Case(file: "CleanShot 2026-11-21 at 18.02.11@2x.png", app: "Finder", expected: "Desktop/Screenshots"),
        Case(file: "Receipt-Amazon-112-4471.pdf", app: "Mail", expected: "Documents/Receipts"),
        Case(file: "Uber Eats receipt.pdf", app: "Mail", expected: "Documents/Receipts"),
        Case(file: "project3_spec.pdf", app: "Safari", expected: "Documents/School/EECS 482"),
        Case(file: "eecs482_lecture12_threads.pdf", app: "Safari", expected: "Documents/School/EECS 482"),
        Case(file: "math217_hw9.pdf", app: "Safari", expected: "Documents/School/Math 217"),
        Case(file: "Linear Algebra Midterm Review.pdf", app: "Safari", expected: "Documents/School/Math 217"),
        Case(file: "IMG_4821.HEIC", app: "Photos", expected: "Documents/Photos"),
        Case(file: "DSC_0042.JPG", app: "Image Capture", expected: "Documents/Photos"),
        Case(file: "track03.mp3", app: "Safari", expected: "Documents/Music"),
        Case(file: "Boarding Pass DTW-SFO.pdf", app: "Mail", expected: "Documents/Travel"),
        Case(file: "Hotel confirmation Marriott.pdf", app: "Mail", expected: "Documents/Travel"),
        Case(file: "Lease Agreement 2027.pdf", app: "Mail", expected: "Documents/Housing"),
        Case(file: "logo-dark@3x.svg", app: "Figma", expected: "Desktop/Design Assets"),
        Case(file: "app-icon-1024.png", app: "Figma", expected: "Desktop/Design Assets"),
        Case(file: "Lab Results Nov.pdf", app: "Safari", expected: "Documents/Medical"),
        Case(file: "Offer Letter - Anthropic.pdf", app: "Mail", expected: "Documents/Offer Letters"),
        Case(file: "NotchViewModel.swift", app: "Xcode", expected: "GitHub/NotchMan"),
        Case(file: "notch-icon.icns", app: "Finder", expected: "GitHub/NotchMan"),
        Case(file: "job_scraper.py", app: "Cursor", expected: "GitHub/JobManager"),
        Case(file: "applications_export.csv", app: "Safari", expected: "GitHub/JobManager"),
        Case(file: "Untitled.txt", app: "TextEdit", expected: "Desktop"),
        Case(file: "installer.dmg", app: "Safari", expected: "Downloads"),
    ]

    @Test func evaluate() async throws {
        try await evaluateWithJev()
    }

    private func evaluateWithJev() async throws {
        let key = ProcessInfo.processInfo.environment["JEV_API_KEY"]!
        let environment = JevTestEnvironment(privacy: .redacted, apiKey: key, identity: ["Jane Doe"]) { request in
            try await URLSession.shared.data(for: request)
        }
        try await JevTestEnvironment.$current.withValue(environment) { try await run() }
    }

    private func run() async throws {
        let home = URL(fileURLWithPath: Self.home)
        let candidates = DropRanking.candidates(
            recents: Self.folders.filter { $0.kind == .recent }.map { home.appending(path: $0.path) },
            projects: Self.folders.filter { $0.kind == .project }.map { home.appending(path: $0.path) },
            places: Self.folders.filter { $0.kind == .place }.map { home.appending(path: $0.path) },
            extra: Self.folders.filter { $0.kind == .folder }.map { home.appending(path: $0.path) })
        var local = (top1: 0, top3: 0), jev = (top1: 0, top3: 0)
        var latencies: [Double] = []
        for test in Self.cases {
            let file = URL(fileURLWithPath: "/tmp/\(test.file)")
            let expected = home.appending(path: test.expected).standardizedFileURL.path
            let localScores = Dictionary(uniqueKeysWithValues: candidates.map {
                ($0.id, DropRanking.localScore(files: [file], candidate: $0, history: DropHistory()))
            })
            let localTop = DropPredictor.top(candidates, scores: localScores).map(\.candidate.id)
            if localTop.first == expected { local.top1 += 1 }
            if localTop.contains(expected) { local.top3 += 1 }

            let request = DropRanking.request(files: [file], candidates: candidates, history: DropHistory(),
                                              context: IntentContext(frontmostApp: test.app, timeOfDay: "weekday afternoon"),
                                              redactor: Jev.redactor())
            let started = Date()
            let answers = try await Jev.ask(state: request.state, questions: request.questions, timeout: 10)
            latencies.append(Date().timeIntervalSince(started) * 1000)
            var scores = localScores
            for (key, candidate) in request.keys {
                scores[candidate.id] = DropRanking.combined(local: localScores[candidate.id] ?? 0, jev: answers[key]?.normalized)
            }
            let jevTop = DropPredictor.top(candidates, scores: scores).map(\.candidate.id)
            if jevTop.first == expected { jev.top1 += 1 }
            if jevTop.contains(expected) { jev.top3 += 1 }
            if jevTop.first != expected {
                print("MISS \(test.file) → \(jevTop.map { URL(fileURLWithPath: $0).lastPathComponent }) (wanted \(test.expected))")
            }
        }
        let n = Self.cases.count
        let sorted = latencies.sorted()
        print("""
        JEV EVAL (\(n) drags, \(candidates.count) folders each)
          local only:  top-1 \(local.top1)/\(n)  top-3 \(local.top3)/\(n)
          with Jev:    top-1 \(jev.top1)/\(n)  top-3 \(jev.top3)/\(n)
          latency ms:  median \(Int(sorted[n / 2]))  p90 \(Int(sorted[n * 9 / 10]))  max \(Int(sorted.last!))
        """)
        #expect(jev.top3 >= local.top3, "Jev shouldn't do worse than the local rules")
    }
}

/// The same drags ranked by the local rules alone, with no history yet (runs without a key).
@MainActor @Suite struct LocalDropBaseline {
    @Test func localRulesAlone() {
        let home = URL(fileURLWithPath: JevDropEval.home)
        let folders = JevDropEval.folders
        let candidates = DropRanking.candidates(
            recents: folders.filter { $0.kind == .recent }.map { home.appending(path: $0.path) },
            projects: folders.filter { $0.kind == .project }.map { home.appending(path: $0.path) },
            places: folders.filter { $0.kind == .place }.map { home.appending(path: $0.path) },
            extra: folders.filter { $0.kind == .folder }.map { home.appending(path: $0.path) })
        var top1 = 0, top3 = 0
        for test in JevDropEval.cases {
            let file = URL(fileURLWithPath: "/tmp/\(test.file)")
            let expected = home.appending(path: test.expected).standardizedFileURL.path
            let scores = Dictionary(uniqueKeysWithValues: candidates.map {
                ($0.id, DropRanking.localScore(files: [file], candidate: $0, history: DropHistory()))
            })
            let top = DropPredictor.top(candidates, scores: scores).map(\.candidate.id)
            if top.first == expected { top1 += 1 }
            if top.contains(expected) { top3 += 1 }
        }
        print("LOCAL BASELINE: top-1 \(top1)/\(JevDropEval.cases.count)  top-3 \(top3)/\(JevDropEval.cases.count)")
    }
}
