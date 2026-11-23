import Foundation
import Testing
import NotchKit
@testable import NotchMods

/// What Claude was asked, in order, with canned replies.
private final class FakeClaude: @unchecked Sendable {
    var calls: [[String]] = []
    var replies: [String]

    init(_ replies: [String]) {
        self.replies = replies
    }

    func run(_ arguments: [String]) -> String {
        calls.append(arguments)
        return replies.isEmpty ? "" : replies.removeFirst()
    }
}

private func reply(_ manifest: String, _ script: String, session: String = "s1") -> String {
    let text = "```json\n\(manifest)\n```\n```javascript\n\(script)\n```"
    let data = try! JSONSerialization.data(withJSONObject: ["result": text, "session_id": session])
    return String(decoding: data, as: UTF8.self)
}

private let goodScript = "function register(on) { on('render', ($, { Text }) => Text('hi')) }"
private let brokenScript = "function register(on) { on('render', ($, { Text }) => Txt('hi')) }"

@MainActor @Suite(.serialized) struct ModGeneratorTests {
    private func library() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "mods-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func aGoodReplyBecomesAnAppFolder() async throws {
        let folder = try library()
        defer { try? FileManager.default.removeItem(at: folder) }
        let claude = FakeClaude([reply(#"{"name":"Water Log","symbol":"drop","height":160}"#, goodScript)])
        let made = try await ModGenerator(claude: { claude.run($0) }).make("track how much water I drink", in: folder)
        #expect(made.lastPathComponent == "water-log")
        #expect(try String(contentsOf: made.appending(path: "app.js"), encoding: .utf8) == goodScript)
        let manifest = try ModManifest.decode(Data(contentsOf: made.appending(path: "manifest.json")))
        #expect(manifest.name == "Water Log" && manifest.symbol == "drop")
        #expect(claude.calls.count == 1)
        let args = try #require(claude.calls.first)
        #expect(args[1].contains("track how much water I drink") && args[1].contains("function register(on)"),
                "the request goes with the authoring guide")
        #expect(args.contains("--disallowedTools") && args.contains("json"), "text only, as JSON for the session id")
    }

    @Test func aBrokenAppIsSentBackToBeFixed() async throws {
        let folder = try library()
        defer { try? FileManager.default.removeItem(at: folder) }
        let claude = FakeClaude([reply(#"{"name":"Hi"}"#, brokenScript), reply(#"{"name":"Hi"}"#, goodScript)])
        _ = try await ModGenerator(claude: { claude.run($0) }).make("say hi", in: folder)
        #expect(claude.calls.count == 2)
        let fix = claude.calls[1]
        #expect(fix.contains("--resume") && fix.contains("s1"), "the fix continues the same conversation")
        #expect(fix[1].contains("Txt"), "with the error that came up: \(fix[1])")
    }

    @Test func itGivesUpAfterTwoFixes() async throws {
        let folder = try library()
        defer { try? FileManager.default.removeItem(at: folder) }
        let broken = reply(#"{"name":"Hi"}"#, brokenScript)
        let claude = FakeClaude([broken, broken, broken])
        await #expect(throws: ModGenerator.Failure.self) {
            _ = try await ModGenerator(claude: { claude.run($0) }).make("say hi", in: folder)
        }
        #expect(claude.calls.count == 3)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true, "nothing written")
    }

    @Test func changingRewritesTheSameFolder() async throws {
        let folder = try library()
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = folder.appending(path: "hi")
        try ModGenerator.write(manifest: ModManifest(name: "Hi"), script: goodScript, to: app)
        let updated = "function register(on) { on('render', ($, { Text }) => Text('hello')) }"
        let claude = FakeClaude([reply(#"{"name":"Hi"}"#, updated)])
        try await ModGenerator(claude: { claude.run($0) }).change(app, "say hello instead")
        #expect(try String(contentsOf: app.appending(path: "app.js"), encoding: .utf8) == updated)
        #expect(claude.calls[0][1].contains(goodScript) && claude.calls[0][1].contains("say hello instead"))
    }

    @Test func repliesAreReadFromTheirBlocks() {
        let text = "Here you go:\n```json\n{\"name\":\"A\"}\n```\nand\n```js\nfunction register(on) {}\n```\nEnjoy"
        let blocks = ModAuthoring.blocks(in: text)
        #expect(blocks?.manifest == "{\"name\":\"A\"}" && blocks?.script == "function register(on) {}")
        #expect(ModAuthoring.blocks(in: "no code here") == nil)
    }

    @Test func foldersAreNamedForTheApp() throws {
        let folder = try library()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(ModGenerator.freeFolder(for: "Pomodoro Timer!", in: folder).lastPathComponent == "pomodoro-timer")
        try FileManager.default.createDirectory(at: folder.appending(path: "pomodoro-timer"), withIntermediateDirectories: true)
        #expect(ModGenerator.freeFolder(for: "Pomodoro Timer", in: folder).lastPathComponent == "pomodoro-timer-2")
        #expect(ModGenerator.freeFolder(for: "🍅", in: folder).lastPathComponent == "app")
    }

    @Test func theGuidesExampleWorks() async throws {
        let blocks = try #require(ModAuthoring.blocks(in: ModAuthoring.guide))
        let manifest = try ModManifest.decode(Data(blocks.manifest.utf8))
        let problem = await ModValidator.check(manifest: manifest, script: blocks.script)
        #expect(problem == nil, "\(problem ?? "")")
    }
}

@MainActor @Suite(.serialized) struct ModLibraryTests {
    private final class Dock {
        var apps: [String] = []
        var revealed: [String] = []
    }

    @Test func theDockFollowsTheFolder() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "mods-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let dock = Dock()
        let library = ModLibrary(folder: folder, add: { dock.apps.append($0.id) },
                                 remove: { id in dock.apps.removeAll { $0 == id } }, reveal: { dock.revealed.append($0) })
        library.start()
        #expect(dock.apps.isEmpty)

        try ModGenerator.write(manifest: ModManifest(name: "Hi", symbol: "hand.wave"), script: goodScript,
                               to: folder.appending(path: "hi"))
        library.scan()
        #expect(dock.apps == ["mod.hi"])
        let app = try #require(library.apps["hi"]?.app)
        #expect(app.name == "Hi" && app.iconSystemName == "hand.wave")

        // Edited: reloads in place (same dock entry).
        try await Task.sleep(for: .milliseconds(1100))  // modification dates have 1 s resolution on some volumes
        try ModGenerator.write(manifest: ModManifest(name: "Hello"), script: goodScript, to: folder.appending(path: "hi"))
        library.scan()
        #expect(dock.apps == ["mod.hi"] && library.apps["hi"]?.app.name == "Hello")

        // A folder without both files isn't an app.
        try FileManager.default.createDirectory(at: folder.appending(path: "half"), withIntermediateDirectories: true)
        library.scan()
        #expect(dock.apps == ["mod.hi"])

        try FileManager.default.removeItem(at: folder.appending(path: "hi"))
        library.scan()
        #expect(dock.apps.isEmpty)
    }

    @Test func theBarOffersToMakeAnApp() {
        let library = ModLibrary(folder: FileManager.default.temporaryDirectory, add: { _ in }, remove: { _ in }, reveal: { _ in })
        #expect(library.commands(for: "water").fallbacks.isEmpty, "one word is a search")
        let rows = library.commands(for: "track my water").fallbacks
        #expect(rows.map(\.id) == ["mods.make"] && rows[0].answer != nil)
    }
}
