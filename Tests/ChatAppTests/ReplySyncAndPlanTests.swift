import Foundation
import Testing
@testable import ChatApp

/// Messages sent mid-turn (a notification reply, or typed while Claude works) and the plan strip after approving a plan.
@MainActor @Suite struct ReplySyncAndPlanTests {
    private func parsed(_ lines: [String]) -> TranscriptParser {
        var parser = TranscriptParser()
        parser.feed(Data((lines.joined(separator: "\n") + "\n").utf8))
        return parser
    }

    // MARK: Mid-turn messages

    /// Shaped like Claude Code 2.1.3xx: a message sent while Claude works is logged only as a queued_command attachment.
    @Test func aMessageSentWhileClaudeWorksShowsAsAPrompt() {
        let parser = parsed([
            #"{"type":"user","uuid":"u1","message":{"role":"user","content":"add stripe checkout"}}"#,
            #"{"type":"assistant","uuid":"a1","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}"#,
            #"{"type":"attachment","uuid":"q1","timestamp":"2026-10-30T17:55:45.199Z","isSidechain":false,"attachment":{"type":"queued_command","prompt":"Use stripe sdk","commandMode":"prompt","origin":{"kind":"human"},"humanTurn":true}}"#,
            #"{"type":"attachment","uuid":"q2","attachment":{"type":"queued_command","prompt":"<task-notification>\n<task-id>b1</task-id>\n</task-notification>","origin":{"kind":"task-notification"}}}"#,
            #"{"type":"attachment","uuid":"q3","attachment":{"type":"queued_command","prompt":"<agent-message from=\"a1\">report</agent-message>","commandMode":"prompt"}}"#,
            #"{"type":"attachment","uuid":"q4","attachment":{"type":"date","date":"2026-11-22"}}"#,
        ])
        let prompts = parser.entries.compactMap { if case .prompt(let text) = $0.kind { text } else { nil } }
        #expect(prompts == ["add stripe checkout", "Use stripe sdk"])
        #expect(parser.turnOpen == true, "it joins the running turn")
    }

    @Test func aQueuedMessageWithAnImageKeepsItsText() {
        let attachment: [String: Any] = ["type": "queued_command", "origin": ["kind": "human"],
                                         "prompt": [["type": "text", "text": "what's wrong here?"], ["type": "image"]]]
        #expect(TranscriptParser.queuedPrompt(attachment) == "what's wrong here?")
    }

    /// What you send shows at once, and gives way to Claude Code's own copy when that's logged.
    @Test func aSentMessageShowsUntilItsLogged() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "pending-\(UUID().uuidString)/project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let file = folder.appending(path: "s1.jsonl")
        try Data((#"{"type":"user","uuid":"u1","message":{"role":"user","content":"start"}}"# + "\n").utf8).write(to: file)
        let transcript = SessionTranscript(sessionID: "s1")
        transcript.readNew(directory: folder.deletingLastPathComponent())
        #expect(transcript.items.count == 1)

        transcript.expect("Use the Stripe SDK")
        transcript.expect("/compact")  // commands show as their own rows once run
        #expect(transcript.items.count == 2)
        #expect(transcript.items.last.map { if case .prompt(_, let text) = $0 { text } else { "" } } == "Use the Stripe SDK")

        let handle = try FileHandle(forWritingTo: file)
        handle.seekToEndOfFile()
        handle.write(Data((#"{"type":"attachment","uuid":"q1","attachment":{"type":"queued_command","prompt":"Use the Stripe SDK","origin":{"kind":"human"}}}"# + "\n").utf8))
        try handle.close()
        transcript.readNew(directory: folder.deletingLastPathComponent())
        #expect(transcript.items.count == 2, "the logged copy replaces the shown one: \(transcript.items)")
        #expect(transcript.entries.count == 2)
    }

    // MARK: Typing a reply into Claude's terminal

    @Test func onlyTheRuledInputBoxCountsAsAPrompt() {
        #expect(AgentTerminal.showsInputBox(["⏺ Done.", "", "────────────", "❯ ", "────────────", "  ? for shortcuts"]))
        // History is still drawing after attaching: an echoed prompt isn't the input box.
        #expect(!AgentTerminal.showsInputBox(["❯ fix the build", "", "⏺ Let me look."]))
        // A permission menu: its highlighted row starts with ❯ too.
        #expect(!AgentTerminal.showsInputBox([
            "────────────",
            " Bash command",
            "   rm -rf build",
            " Do you want to proceed?",
            " ❯ 1. Yes",
            "   2. No",
            "",
            " Esc to cancel",
        ]))
    }

    // MARK: The plan strip after approving a plan

    private func approvedPlan(_ plan: String, result: String = "User has approved your plan. You can now start coding.",
                              isError: Bool = false) -> [String] {
        let input = try! JSONSerialization.data(withJSONObject: ["plan": plan])
        return [
            #"{"type":"user","uuid":"u1","message":{"role":"user","content":"plan the hackathon"}}"#,
            #"{"type":"assistant","uuid":"a1","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"p1","name":"ExitPlanMode","input":"# + String(data: input, encoding: .utf8)! + "}]}}",
            #"{"type":"user","uuid":"r1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"p1","content":"# + "\"\(result)\"" + #","is_error":"# + "\(isError)" + "}]}}",
        ]
    }

    private let hackathonPlan = """
        # Plan: Personal AI assistant platform

        ## Context
        `slides.pdf` is the full spec.

        ## Decisions (you chose all of these)
        1. Python backend
        2. React frontend

        ## Build order (commit after each step)
        1. Design doc (`docs/designs/platform.md`) via elephant (short), one goldfish round, fixes. Commit.
        2. Agent image + smoke script: create a container and run one real turn through the SDK. This is the riskiest piece, so prove it first.
        3. **E2E slice:** register/login → create agent → chat turn streams to the browser. Commit.
           - nested detail
        4. Event persistence + replay + Stop. Commit.

        ## Verification
        1. Run the tests
        """

    @Test func approvingAPlanShowsItsSteps() {
        let parser = parsed(approvedPlan(hackathonPlan))
        #expect(parser.todosFromPlan)
        #expect(parser.todos.map(\.title) == [
            "Design doc (docs/designs/platform.md) via elephant (short), one…",
            "Agent image + smoke script: create a container and run one real turn…",
            "E2E slice",
            "Event persistence + replay + Stop. Commit.",
        ])
        #expect(parser.todos.allSatisfy { $0.status == .pending })
    }

    @Test func aRejectedPlanShowsNothing() {
        let parser = parsed(approvedPlan(hackathonPlan, result: "The user doesn't want to proceed with this tool use.", isError: true))
        #expect(parser.todos.isEmpty && !parser.todosFromPlan)
    }

    @Test func claudesOwnListReplacesThePlansSteps() {
        let parser = parsed(approvedPlan(hackathonPlan) + [
            #"{"type":"assistant","uuid":"a2","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"TaskCreate","input":{"subject":"Write the design doc"}}]}}"#,
            #"{"type":"user","uuid":"r2","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"Task #1 created successfully: Write the design doc"}]}}"#,
            // Logged twice, as Claude Code sometimes does: still one task.
            #"{"type":"assistant","uuid":"a2b","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"TaskCreate","input":{"subject":"Write the design doc"}}]}}"#,
            #"{"type":"user","uuid":"r2b","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"Task #1 created successfully: Write the design doc"}]}}"#,
        ])
        #expect(!parser.todosFromPlan)
        #expect(parser.todos.map(\.title) == ["Write the design doc"])
    }

    @Test func thePlansStepsGoAtYourNextPrompt() {
        let parser = parsed(approvedPlan(hackathonPlan) + [
            #"{"type":"user","uuid":"u2","message":{"role":"user","content":"something else now"}}"#,
        ])
        #expect(parser.todos.isEmpty && !parser.todosFromPlan)
    }

    // MARK: Reading steps out of a plan

    @Test func stepsComeFromTheOrderOfWorkFirst() {
        let plan = """
            # Roadmap
            ## Context
            Why.
            ## Components
            1. **Context snapshot (`NotchKit/IntentContext.swift`)**: one struct.
            2. **Jev client**: a POST.
            ## Phases
            0. **Fixes (track B):**
            1. **Groundwork and Shelf:** components 1, 2 and 5.
            2. **Command bar:** component 6.
            ## Verification
            - build
            """
        #expect(PlanSteps.steps(plan) == ["Fixes (track B)", "Groundwork and Shelf", "Command bar"])
    }

    @Test func aChangesSectionListsFiles() {
        let plan = """
            # Draft answers
            ## Context
            Text.
            ## Battery rules
            1. Nothing runs until you click Draft.
            2. One request per page.
            ## Changes (NotchMan only)
            - **`Sources/Apps/JobsApp/AnswerDrafter.swift`** (new):
              - `DraftContext.build`: details
            - **`PageAssist.swift`**: add `category`.
            - **Tests**, in `Tests/JobsAppTests/AnswerDrafterTests.swift`: request body.
            ## Verification
            1. Run it
            """
        #expect(PlanSteps.steps(plan) == ["AnswerDrafter.swift", "PageAssist.swift", "Tests"])
    }

    @Test func subheadingsWhenTheSectionHasNoList() {
        let plan = """
            # Phase 1 eval
            ## Context
            Text.
            ## Changes to `phase_1.ipynb`, by phase
            ### Build (step 1): labeled personas
            Text.
            ### Measure (step 2): fixed flow
            Text.
            ### Analyze (steps 3 and 4)
            Text.
            ## Files
            - a.py
            """
        #expect(PlanSteps.steps(plan) == ["Build (step 1): labeled personas", "Measure (step 2): fixed flow", "Analyze (steps 3 and 4)"])
    }

    @Test func otherwiseThePlansHeadings() {
        let plan = """
            # Pipeline test suite
            ## Context
            Text.
            ## Layer 1 — offline stage tests (`npm run test:stages`)
            - `harness.ts`: loads env.
            ## Layer 2 — live redirect mode
            Text.
            ## Critical files
            - a.ts
            ## Verification
            1. Run it.
            """
        #expect(PlanSteps.steps(plan) == ["Layer 1 — offline stage tests (npm run test:stages)", "Layer 2 — live redirect mode"])
    }

    @Test func aPlanWithoutStepsGivesNone() {
        #expect(PlanSteps.steps("# Fix the typo\n\nChange `teh` to `the` in README.md.").isEmpty)
    }
}
