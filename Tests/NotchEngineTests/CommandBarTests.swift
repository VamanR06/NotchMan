import Foundation
import Testing
import NotchKit
@testable import NotchEngine

/// What ran, for checking the bar's behavior.
@MainActor private final class Ran {
    var items: [String] = []
    var actions: [String] = []
    var revealed: [String?] = []
}

@MainActor @Suite(.serialized) struct CommandBarTests {
    private func bar(_ ran: Ran) -> CommandBarModel {
        let bar = CommandBarModel()
        bar.debounce = .zero
        let file = CommandParameter(name: "file", description: "file",
                                    choices: [CommandChoice(id: "/r.pdf", label: "resume.pdf", path: "/r.pdf", kind: .file)])
        let folder = CommandParameter(name: "folder", description: "folder",
                                      choices: [CommandChoice(id: "/R", label: "Resumes", path: "/R", kind: .folder)])
        bar.commands = { _ in
            NotchCommands(
                items: [
                    CommandItem(id: "resume", title: "resume.pdf", symbol: "doc", kind: "File") { ran.items.append("resume") },
                    CommandItem(id: "folder", title: "Resumes", symbol: "folder", kind: "Folder") { ran.items.append("folder") },
                ],
                actions: [
                    CommandAction(id: "put_file", description: "Put a file into a folder", risk: .confirm, symbol: "folder",
                                  parameters: [file, folder], summary: { "Move \($0["file"]!.label) to \($0["folder"]!.label)" },
                                  perform: { _ in ran.actions.append("put_file") }),
                    CommandAction(id: "open_file", description: "Open a file", risk: .safe, symbol: "doc",
                                  parameters: [file], summary: { _ in "Open" }, perform: { _ in ran.actions.append("open_file") }),
                ])
        }
        bar.onRun = { ran.revealed.append($0) }
        return bar
    }

    private func jev(tool: String, _ body: () async throws -> Void) async throws {
        let reply = Data("""
        {"answers":{"__tool__":{"type":"choice","choice":"\(tool)","confidence":0.9,"probabilities":{"\(tool)":0.9}},
        "put_file.file":{"type":"choice","choice":"o1","confidence":0.9,"probabilities":{"o1":0.9}},
        "put_file.folder":{"type":"choice","choice":"o1","confidence":0.85,"probabilities":{"o1":0.85}},
        "open_file.file":{"type":"choice","choice":"o1","confidence":0.9,"probabilities":{"o1":0.9}}}}
        """.utf8)
        let environment = JevTestEnvironment(privacy: .redacted, apiKey: "k", identity: []) { request in
            (reply, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        try await JevTestEnvironment.$current.withValue(environment) { try await body() }
    }

    private func waitForJev(_ bar: CommandBarModel) async throws {
        for _ in 0..<100 where bar.isAsking { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func typingShowsLocalMatchesThenAskClaude() {
        let ran = Ran()
        let bar = bar(ran)
        bar.query = "resum"
        #expect(bar.rows.map(\.id) == ["item:folder", "item:resume", "ask"])
        bar.move(1)
        bar.runSelected()
        #expect(ran.items == ["resume"] && ran.revealed == [nil])
        #expect(bar.query.isEmpty, "the bar resets after running")
    }

    @Test func jevsReadingGoesOnTopAndRiskyActionsAskFirst() async throws {
        let ran = Ran()
        let bar = bar(ran)
        try await jev(tool: "put_file") {
            bar.query = "move my resume to resumes"
            try await waitForJev(bar)
        }
        guard case .action(let reading, let action)? = bar.rows.first else {
            Issue.record("expected Jev's reading first: \(bar.rows.map(\.id))")
            return
        }
        #expect(action.summary(reading.choices) == "Move resume.pdf to Resumes" && reading.confidence == 0.85)
        #expect(bar.selection == 0)
        bar.runSelected()
        #expect(ran.actions.isEmpty && bar.confirming == "action:put_file", "first Return asks")
        bar.runSelected()
        #expect(ran.actions == ["put_file"], "second Return runs it")
    }

    @Test func safeActionsRunOnTheFirstReturn() async throws {
        let ran = Ran()
        let bar = bar(ran)
        try await jev(tool: "open_file") {
            bar.query = "open my resume"
            try await waitForJev(bar)
        }
        bar.runSelected()
        #expect(ran.actions == ["open_file"])
    }

    @Test func oneWordIsJustASearch() async throws {
        #expect(!CommandBarModel.shouldAskJev("resume"))
        #expect(CommandBarModel.shouldAskJev("open resume"))
    }

    @Test func anAnswerForOlderTextIsIgnored() async throws {
        let ran = Ran()
        let bar = bar(ran)
        bar.debounce = .milliseconds(30)
        try await jev(tool: "put_file") {
            bar.query = "move my resume"
            bar.query = "resum"  // typed on before Jev answered (and one word: no new request)
            try await Task.sleep(for: .milliseconds(150))
        }
        #expect(!bar.rows.contains { if case .action = $0 { true } else { false } })
    }

    @Test func movingOffAConfirmationCancelsIt() async throws {
        let ran = Ran()
        let bar = bar(ran)
        try await jev(tool: "put_file") {
            bar.query = "move my resume to resumes"
            try await waitForJev(bar)
        }
        bar.runSelected()
        bar.move(1)
        #expect(bar.confirming == nil)
        bar.move(-1)
        bar.runSelected()
        #expect(ran.actions.isEmpty, "asks again")
    }

    @Test func fallbacksFollowTheMatchesAndReplaceAskClaude() {
        let ran = Ran()
        let bar = bar(ran)
        let commands = bar.commands
        bar.commands = { query in
            var offered = commands(query)
            offered.fallbacks = [CommandItem(id: "claude.ask", title: "Ask Claude", symbol: "sparkle", kind: "Claude", answer: { _ in "42" })]
            return offered
        }
        bar.query = "resum"
        #expect(bar.rows.map(\.id) == ["item:folder", "item:resume", "item:claude.ask"])
    }

    @Test func anAnswerShowsInTheBarUntilEscOrTyping() async throws {
        let ran = Ran()
        let bar = bar(ran)
        bar.commands = { _ in
            NotchCommands(fallbacks: [CommandItem(id: "ask", title: "Ask Claude", symbol: "sparkle", kind: "Claude", answer: { progress in
                progress("It's")
                try await Task.sleep(for: .milliseconds(50))
                return "It's 42."
            })])
        }
        bar.query = "meaning of life"
        bar.runSelected()
        #expect(bar.answer?.title == "Ask Claude")
        for _ in 0..<50 where bar.answer?.text == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(bar.answer?.text == "It's" && bar.answer?.isLoading == true, "shows the answer as it comes")
        for _ in 0..<50 where bar.answer?.isDone != true { try await Task.sleep(for: .milliseconds(10)) }
        #expect(bar.answer?.text == "It's 42." && ran.revealed.isEmpty, "the bar stays open with the answer")
        bar.runSelected()
        #expect(bar.answer != nil, "Return doesn't run it again")
        bar.closeAnswer()
        #expect(bar.answer == nil && bar.query == "meaning of life", "Esc goes back to the results")
        bar.runSelected()
        bar.query = "meaning of lif"
        #expect(bar.answer == nil, "typing goes back too")
    }

    @Test func anItemThatActsAsksFirst() {
        let ran = Ran()
        let bar = bar(ran)
        bar.commands = { _ in
            NotchCommands(fallbacks: [CommandItem(id: "agent", title: "Start an agent", symbol: "terminal", kind: "Claude",
                                                  needsConfirm: true) { ran.items.append("agent") }])
        }
        bar.query = "do the thing"
        bar.runSelected()
        #expect(ran.items.isEmpty && bar.confirming == "item:agent")
        bar.runSelected()
        #expect(ran.items == ["agent"])
    }
}
