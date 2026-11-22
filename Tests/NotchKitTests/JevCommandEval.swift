import Foundation
import Testing
@testable import NotchKit

/// How often Jev reads a typed request as the right action with the right choices, on 16 typical requests. Calls the
/// real service, so it only runs with a key:
///
///     JEV_API_KEY=sk-… swift test --filter JevCommandEval
@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["JEV_API_KEY"] != nil))
struct JevCommandEval {
    private static func choices(_ labels: [String], kind: CommandChoice.Kind = .text) -> [CommandChoice] {
        labels.map { CommandChoice(id: $0, label: $0, path: kind == .text ? nil : NSHomeDirectory() + "/" + $0, kind: kind) }
    }

    private static let files = choices(["Downloads/Jane_Doe_Resume_2026.pdf", "Downloads/W2_2026.pdf",
                                        "Desktop/Screenshot 2026-11-22 at 10.15.png", "Downloads/lease.pdf"], kind: .file)
    private static let folders = choices(["Documents/Resumes", "Documents/Taxes", "Desktop/Screenshots",
                                          "Documents/Housing", "GitHub/NotchMan"], kind: .folder)
    private static let agents = choices(["fix-build (project NotchMan, Needs you)", "write-tests (project JobManager, Working)",
                                         "refactor-shelf (project NotchMan, Done)"])
    private static let requests = choices(["Bash wants to run npm test in project JobManager",
                                           "Edit wants to change ShelfView.swift in project NotchMan"])
    private static let tasks = choices(["Call recruiter (Due Nov 22)", "Submit EECS 482 project 3 (Due Nov 24)",
                                        "Buy groceries"])

    private static var actions: [CommandAction] {
        func action(_ id: String, _ description: String, _ parameters: [CommandParameter]) -> CommandAction {
            CommandAction(id: id, description: description, risk: .safe, symbol: "x", parameters: parameters,
                          summary: { _ in "" }, perform: { _ in })
        }
        let file = CommandParameter(name: "file", description: "file", choices: files)
        let folder = CommandParameter(name: "folder", description: "folder", choices: folders)
        return [
            action("put_file", "Put a file into a folder (move or copy it there)", [file, folder]),
            action("open_file", "Open a file in its app", [file]),
            action("preview_file", "Preview a file (Quick Look)", [file]),
            action("open_folder", "Open a folder in Finder", [folder]),
            action("open_agent", "Open a Claude Code session", [CommandParameter(name: "agent", description: "Claude Code session", choices: agents)]),
            action("allow_request", "Allow (approve) a pending permission request",
                   [CommandParameter(name: "request", description: "pending permission request", choices: requests)]),
            action("deny_request", "Deny a pending permission request",
                   [CommandParameter(name: "request", description: "pending permission request", choices: requests)]),
            action("complete_task", "Check off (complete) a task", [CommandParameter(name: "task", description: "task", choices: tasks)]),
        ]
    }

    /// Request → expected action and choice ids (nil action: nothing listed fits).
    private static let cases: [(String, String?, [String: String])] = [
        ("move the resume i just downloaded to my resumes folder", "put_file",
         ["file": "Downloads/Jane_Doe_Resume_2026.pdf", "folder": "Documents/Resumes"]),
        ("file my w2 with the taxes", "put_file", ["file": "Downloads/W2_2026.pdf", "folder": "Documents/Taxes"]),
        ("put that screenshot in screenshots", "put_file",
         ["file": "Desktop/Screenshot 2026-11-22 at 10.15.png", "folder": "Desktop/Screenshots"]),
        ("lease goes in housing", "put_file", ["file": "Downloads/lease.pdf", "folder": "Documents/Housing"]),
        ("open my resume", "open_file", ["file": "Downloads/Jane_Doe_Resume_2026.pdf"]),
        ("let me see the lease", "preview_file", ["file": "Downloads/lease.pdf"]),
        ("show the taxes folder", "open_folder", ["folder": "Documents/Taxes"]),
        ("open the notchman repo", "open_folder", ["folder": "GitHub/NotchMan"]),
        ("go to the agent that needs me", "open_agent", ["agent": "fix-build (project NotchMan, Needs you)"]),
        ("check on the jobmanager tests agent", "open_agent", ["agent": "write-tests (project JobManager, Working)"]),
        ("approve the npm test", "allow_request", ["request": "Bash wants to run npm test in project JobManager"]),
        ("yes let it edit shelfview", "allow_request", ["request": "Edit wants to change ShelfView.swift in project NotchMan"]),
        ("don't let it run npm test", "deny_request", ["request": "Bash wants to run npm test in project JobManager"]),
        ("i called the recruiter", "complete_task", ["task": "Call recruiter (Due Nov 22)"]),
        ("done with groceries", "complete_task", ["task": "Buy groceries"]),
        ("what's the weather tomorrow", nil, [:]),
    ]

    @Test func evaluate() async throws {
        let key = ProcessInfo.processInfo.environment["JEV_API_KEY"]!
        let environment = JevTestEnvironment(privacy: .redacted, apiKey: key, identity: ["Jane Doe"]) { request in
            try await URLSession.shared.data(for: request)
        }
        try await JevTestEnvironment.$current.withValue(environment) { try await run() }
    }

    private func run() async throws {
        var right = 0
        var latencies: [Double] = []
        for (query, expectedAction, expectedChoices) in Self.cases {
            let request = CommandRouting.request(query: query, actions: Self.actions,
                                                 context: IntentContext(frontmostApp: "Finder", timeOfDay: "weekday afternoon"),
                                                 redactor: Jev.redactor())
            let started = Date()
            let answers = try await Jev.ask(state: request.state, questions: request.questions, timeout: 10)
            latencies.append(Date().timeIntervalSince(started) * 1000)
            let reading = CommandRouting.interpret(answers, actions: Self.actions, options: request.options)
            let ok = reading?.actionID == expectedAction && (reading?.choices.mapValues(\.id) ?? [:]) == expectedChoices
            if ok { right += 1 } else {
                print("MISS “\(query)” → \(reading.map { "\($0.actionID) \($0.choices.mapValues(\.id))" } ?? "nothing") (wanted \(expectedAction ?? "nothing") \(expectedChoices))")
            }
        }
        let sorted = latencies.sorted(), n = Self.cases.count
        print("JEV COMMANDS: \(right)/\(n) right · latency ms median \(Int(sorted[n / 2])) p90 \(Int(sorted[n * 9 / 10]))")
    }
}
