import Foundation
import Testing
@testable import NotchKit

@MainActor @Suite struct CommandRoutingTests {
    private func item(_ title: String, kind: String = "File", keywords: [String] = []) -> CommandItem {
        CommandItem(id: title, title: title, symbol: "doc", kind: kind, keywords: keywords) {}
    }

    @Test func searchPrefersWordStartsThenAnywhereThenDetails() {
        let items = [item("Old Resumes"), item("Resumes"), item("presume.txt"), item("NotchMan", kind: "Folder"),
                     item("budget.xlsx", keywords: ["resume"])]
        #expect(CommandRouting.search("resu", in: items).map(\.title) == ["Resumes", "Old Resumes", "presume.txt", "budget.xlsx"])
        #expect(CommandRouting.search("nmn", in: items).map(\.title) == ["NotchMan"], "letters in order")
        #expect(CommandRouting.search("folder notch", in: items).map(\.title) == ["NotchMan"], "every word must match")
        #expect(CommandRouting.search("zzz", in: items).isEmpty)
    }

    @Test func aSentenceStillFindsWhatItNames() {
        let items = [item("Resume_2026.pdf"), item("Resumes", kind: "Folder"), item("photo.png")]
        let found = CommandRouting.search("move the resume i downloaded to resumes", in: items).map(\.title)
        #expect(Set(found) == ["Resume_2026.pdf", "Resumes"])
    }

    private var actions: [CommandAction] {
        let file = CommandParameter(name: "file", description: "file", choices: [
            CommandChoice(id: "/x/Jane_Doe_Resume.pdf", label: "Jane_Doe_Resume.pdf", path: NSHomeDirectory() + "/Downloads/Jane_Doe_Resume.pdf", kind: .file),
            CommandChoice(id: "/x/photo.png", label: "photo.png", path: "/x/photo.png", kind: .file),
        ])
        let folder = CommandParameter(name: "folder", description: "folder", choices: [
            CommandChoice(id: "/r", label: "Resumes", path: NSHomeDirectory() + "/Documents/Resumes", kind: .folder),
        ])
        return [
            CommandAction(id: "put_file", description: "Put a file into a folder", risk: .confirm, symbol: "folder",
                          parameters: [file, folder], summary: { _ in "" }, perform: { _ in }),
            CommandAction(id: "open_file", description: "Open a file", risk: .safe, symbol: "doc",
                          parameters: [file], summary: { _ in "" }, perform: { _ in }),
        ]
    }

    @Test func theRequestListsEveryActionAndChoiceRedacted() {
        let request = CommandRouting.request(query: "move Jane's resume to resumes, tell jane.doe@gmail.com",
                                             actions: actions, context: IntentContext(frontmostApp: nil, timeOfDay: "x"),
                                             redactor: Redactor(identity: ["Jane Doe", "jane.doe@gmail.com"]))
        #expect(Set(request.questions.keys) == ["__tool__", "put_file.file", "put_file.folder", "open_file.file"])
        #expect(Redactor.leaks(in: request.state, identity: ["Jane Doe", "jane.doe@gmail.com"]).isEmpty)
        let body = JSONValue.object(request.questions.mapValues(\.json))
        #expect(Redactor.leaks(in: body, identity: ["Jane Doe"]).isEmpty, "choices are redacted too")
        guard case .choice(let options) = request.questions["put_file.folder"]?.kind else {
            Issue.record("expected a choice")
            return
        }
        #expect(options["o1"] == "~/Documents/Resumes" && options["none"] != nil)
        #expect(request.options["put_file.file"]?["o1"]?.id == "/x/Jane_Doe_Resume.pdf")
    }

    private func answers(tool: String, _ toolP: Double, file: String = "o1", _ fileP: Double = 0.9,
                         folder: String = "o1", _ folderP: Double = 0.8) -> [String: JevAnswer] {
        [
            "__tool__": .choice(tool, confidence: toolP, probabilities: [tool: toolP]),
            "put_file.file": .choice(file, confidence: fileP, probabilities: [file: fileP]),
            "put_file.folder": .choice(folder, confidence: folderP, probabilities: [folder: folderP]),
            "open_file.file": .choice(file, confidence: fileP, probabilities: [file: fileP]),
        ]
    }

    private var options: [String: [String: CommandChoice]] {
        CommandRouting.request(query: "x", actions: actions, context: IntentContext(frontmostApp: nil, timeOfDay: "x"),
                               redactor: Redactor(identity: [])).options
    }

    @Test func aConfidentReadingFillsEveryParameter() {
        let reading = CommandRouting.interpret(answers(tool: "put_file", 0.95), actions: actions, options: options)
        #expect(reading?.actionID == "put_file")
        #expect(reading?.choices["file"]?.id == "/x/Jane_Doe_Resume.pdf" && reading?.choices["folder"]?.id == "/r")
        #expect(reading?.confidence == 0.8, "the least sure decision")
    }

    @Test func unsureOrIncompleteReadingsAreNotOffered() {
        #expect(CommandRouting.interpret(answers(tool: "none", 0.9), actions: actions, options: options) == nil)
        #expect(CommandRouting.interpret(answers(tool: "put_file", 0.4), actions: actions, options: options) == nil)
        #expect(CommandRouting.interpret(answers(tool: "put_file", 0.9, folder: "none", 0.9), actions: actions, options: options) == nil)
        #expect(CommandRouting.interpret(answers(tool: "put_file", 0.9, 0.2), actions: actions, options: options) == nil)
        #expect(CommandRouting.interpret(answers(tool: "unknown", 0.9), actions: actions, options: options) == nil)
    }
}
