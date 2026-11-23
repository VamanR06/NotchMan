import Foundation
import Testing
import NotchKit
@testable import NotchMods

/// Runs a script and collects what it sends back.
@MainActor private final class Harness {
    let runtime: ModRuntime
    var trees: [Result<ModNode, ModError>] = []
    var errors: [String] = []
    var chips: [ModChip?] = []

    init(_ script: String, manifest: ModManifest = ModManifest(name: "Test"), storeURL: URL? = nil) {
        runtime = ModRuntime(manifest: manifest, storeURL: storeURL)
        runtime.onTree = { [unowned self] in trees.append($0) }
        runtime.onError = { [unowned self] in errors.append($0) }
        runtime.onChip = { [unowned self] in chips.append($0) }
        runtime.start(script: script)
    }

    var lastTree: ModNode? { if case .success(let node)? = trees.last { node } else { nil } }
    var lastFailure: ModError? { if case .failure(let error)? = trees.last { error } else { nil } }

    func waitForTrees(_ count: Int) async throws {
        for _ in 0..<200 where trees.count < count { try await Task.sleep(for: .milliseconds(10)) }
    }
}

@MainActor @Suite(.serialized) struct ModRuntimeTests {
    private let counter = """
    let count = 0
    export function register(on) {
      on('app.start', ($) => { count = $.store.get('count') ?? 0 })
      on('render', ($, { Column, Text, Button }) => Column({ gap: 8 },
        Text({ size: 'title', text: 'Count: ' + count }),
        Button({ label: 'Add one', variant: 'primary', onPress: () => { count += 1; $.store.set('count', count); $.ui.chip({ text: String(count), symbol: 'plus' }) } })
      ))
    }
    """

    @Test func drawsWhatRenderReturns() async throws {
        let harness = Harness(counter)
        try await harness.waitForTrees(1)
        let tree = try #require(harness.lastTree)
        #expect(tree.type == "Column" && tree.children.map(\.type) == ["Text", "Button"])
        #expect(tree.children[0].text == "Count: 0")
        #expect(tree.children[1].handler("onPress") != nil, "callbacks become handler ids")
    }

    @Test func aPressRunsItsCallbackAndRedraws() async throws {
        let harness = Harness(counter)
        try await harness.waitForTrees(1)
        let id = try #require(harness.lastTree?.children[1].handler("onPress"))
        harness.runtime.send(id, value: nil)
        try await harness.waitForTrees(2)
        #expect(harness.lastTree?.children[0].text == "Count: 1")
        #expect(harness.chips.last == ModChip(text: "1", symbol: "plus", color: nil))
    }

    @Test func savedValuesLastAcrossRestarts() async throws {
        let store = FileManager.default.temporaryDirectory.appending(path: "mod-store-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: store) }
        let first = Harness(counter, storeURL: store)
        try await first.waitForTrees(1)
        first.runtime.send(try #require(first.lastTree?.children[1].handler("onPress")), value: nil)
        try await first.waitForTrees(2)
        try await Task.sleep(for: .milliseconds(200))  // saved in the background
        let second = Harness(counter, storeURL: store)
        try await second.waitForTrees(1)
        #expect(second.lastTree?.children[0].text == "Count: 1")
    }

    @Test func inputsPassTheirTextToTheCallback() async throws {
        let harness = Harness("""
        let items = []
        function register(on) {
          on('render', ($, { Column, Input, List, Text }) => Column({},
            Input({ placeholder: 'Add', onSubmit: (text) => { items.push(text) } }),
            List({}, items.map(i => Text(i)))))
        }
        """)
        try await harness.waitForTrees(1)
        harness.runtime.send(try #require(harness.lastTree?.children[0].handler("onSubmit")), value: .string("milk"))
        try await harness.waitForTrees(2)
        #expect(harness.lastTree?.children[1].children.map(\.text) == ["milk"])
    }

    @Test func mistakesAreReportedForTheAuthorToFix() async throws {
        let syntax = Harness("function register(on) { on('render', () => Box( }")
        try await syntax.waitForTrees(1)
        guard case .script(let message)? = syntax.lastFailure else { Issue.record("expected a script error"); return }
        #expect(message.contains("loading the script"))

        let unknown = Harness("function register(on) { on('render', () => ({ type: 'Spinner', props: {}, children: [] })) }")
        try await unknown.waitForTrees(1)
        guard case .badTree(let detail)? = unknown.lastFailure else { Issue.record("expected a bad tree"); return }
        #expect(detail.contains("Spinner"))

        let none = Harness("function register(on) { on('app.start', () => {}) }")
        try await none.waitForTrees(1)
        #expect(none.lastFailure == .noRender)

        let missing = Harness("const x = 1")
        try await missing.waitForTrees(1)
        guard case .script(let reason)? = missing.lastFailure else { Issue.record("expected a script error"); return }
        #expect(reason.contains("register"))
    }

    @Test func timersTickAndRedraw() async throws {
        let harness = Harness("""
        let ticks = 0
        function register(on) {
          on('app.start', ($) => { $.clock.every(250, () => { ticks += 1 }) })
          on('render', ($, { Text }) => Text('ticks ' + ticks))
        }
        """)
        try await harness.waitForTrees(3)
        #expect(harness.lastTree.map { $0.text != "ticks 0" } == true)
        harness.runtime.stop()
    }

    @Test func theNetworkNeedsThePermission() async throws {
        let harness = Harness("""
        let result = 'waiting'
        function register(on) {
          on('app.start', async ($) => {
            try { await $.http.fetch('https://example.com'); result = 'fetched' } catch (e) { result = 'refused: ' + e.message }
          })
          on('render', ($, { Text }) => Text(result))
        }
        """)
        for _ in 0..<200 where !(harness.lastTree?.text.hasPrefix("refused") ?? false) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(harness.lastTree?.text.contains("network permission") == true)
    }

    @Test func aThrowingCallbackKeepsTheDrawing() async throws {
        let harness = Harness("""
        function register(on) {
          on('render', ($, { Button }) => Button({ label: 'Boom', onPress: () => { throw new Error('nope') } }))
        }
        """)
        try await harness.waitForTrees(1)
        harness.runtime.send(try #require(harness.lastTree?.handler("onPress")), value: nil)
        try await harness.waitForTrees(2)
        #expect(harness.errors.contains { $0.contains("nope") })
        #expect(harness.lastTree?.type == "Button", "still drawn")
    }

    @Test func manifestsNeedAName() throws {
        #expect(try ModManifest.decode(Data(#"{"name":"Pomodoro","symbol":"timer","permissions":["network"]}"#.utf8)).allowsNetwork)
        #expect(throws: ModError.self) { try ModManifest.decode(Data(#"{"name":"  "}"#.utf8)) }
        #expect(throws: ModError.self) { try ModManifest.decode(Data("nope".utf8)) }
    }
}
