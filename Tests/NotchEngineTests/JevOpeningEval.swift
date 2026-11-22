import Foundation
import Testing
import NotchKit
@testable import NotchEngine

/// How often Jev opens the notch to the app you'd want, on 10 typical moments. Calls the real service, so it only runs
/// with a key:
///
///     JEV_API_KEY=sk-… swift test --filter JevOpeningEval
@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["JEV_API_KEY"] != nil))
struct JevOpeningEval {
    private struct Moment {
        let front: String
        let time: String
        let last: String
        let statuses: [String: NotchRelevance?]
        /// What should show; `last` means stay.
        let expected: String
    }

    private static let names = ["today": "Today", "calendar": "Calendar", "tasks": "Tasks", "jobs": "Jobs",
                                "chat": "Agents", "music": "Now Playing", "shelf": "Shelf"]

    private static let moments: [Moment] = [
        Moment(front: "Zoom", time: "weekday morning", last: "music",
               statuses: ["calendar": NotchRelevance("Meeting “Standup” starts in 2 min", urgent: true)], expected: "calendar"),
        Moment(front: "Terminal", time: "weekday afternoon", last: "calendar",
               statuses: ["chat": NotchRelevance("Claude Code is waiting for permission to use Bash", urgent: true)], expected: "chat"),
        Moment(front: "Spotify", time: "weekday evening", last: "tasks",
               statuses: ["music": NotchRelevance("Music playing: “Midnight City”")], expected: "music"),
        Moment(front: "Safari", time: "weekday afternoon", last: "today",
               statuses: ["jobs": NotchRelevance("The browser shows one of the user's tracked job applications")], expected: "jobs"),
        Moment(front: "Finder", time: "weekday morning", last: "calendar",
               statuses: ["shelf": NotchRelevance("Downloading a file (64%)")], expected: "shelf"),
        Moment(front: "Notion", time: "weekday morning", last: "music",
               statuses: ["tasks": NotchRelevance("3 overdue task(s), 2 due today")], expected: "tasks"),
        Moment(front: "Xcode", time: "weekday afternoon", last: "chat",
               statuses: ["chat": NotchRelevance("2 Claude Code session(s) working"), "music": NotchRelevance("Music playing: “Intro”")],
               expected: "chat"),
        Moment(front: "Mail", time: "weekday morning", last: "today",
               statuses: ["tasks": NotchRelevance("1 task(s) due today"), "shelf": NotchRelevance("2 file(s) kept on the shelf")],
               expected: "today"),
        Moment(front: "Slack", time: "weekday afternoon", last: "shelf",
               statuses: ["calendar": NotchRelevance("Meeting “Design review” is happening now", urgent: true)], expected: "calendar"),
        Moment(front: "Safari", time: "weekend evening", last: "music",
               statuses: ["music": NotchRelevance("Music playing: “Something”"), "tasks": NotchRelevance("1 task(s) due today")],
               expected: "music"),
    ]

    @Test func evaluate() async throws {
        let key = ProcessInfo.processInfo.environment["JEV_API_KEY"]!
        let environment = JevTestEnvironment(privacy: .redacted, apiKey: key, identity: []) { request in
            try await URLSession.shared.data(for: request)
        }
        try await JevTestEnvironment.$current.withValue(environment) { try await run() }
    }

    private func run() async throws {
        var jevRight = 0, localRight = 0
        var latencies: [Double] = []
        for moment in Self.moments {
            let states = Self.names.keys.sorted().map { id in
                OpeningChooser.AppState(id: id, name: Self.names[id]!, relevance: (moment.statuses[id] ?? nil)
                                            ?? (id == "today" ? NotchRelevance("The day at a glance: meetings, tasks due, agents") : nil))
            }
            let request = OpeningChooser.request(apps: states, current: moment.last,
                                                 context: IntentContext(frontmostApp: moment.front, timeOfDay: moment.time),
                                                 redactor: Jev.redactor())
            let started = Date()
            let answers = try await Jev.ask(state: request.state, questions: request.questions, timeout: 10)
            latencies.append(Date().timeIntervalSince(started) * 1000)
            let shown = OpeningChooser.pick(answers, current: moment.last, apps: states) ?? moment.last
            let local = OpeningChooser.localPick(apps: states, current: moment.last) ?? moment.last
            if shown == moment.expected { jevRight += 1 } else { print("MISS \(moment.front)/\(moment.last) → \(shown) (wanted \(moment.expected))") }
            if local == moment.expected { localRight += 1 }
        }
        let sorted = latencies.sorted(), n = Self.moments.count
        print("JEV OPENING: Jev \(jevRight)/\(n) · urgent-only rule \(localRight)/\(n) · latency ms median \(Int(sorted[n / 2])) max \(Int(sorted.last!))")
    }
}
