import Foundation
import Testing
@testable import NotchKit

/// The osascript runner Autofill uses to talk to the browser.
@Suite struct AppleScriptRunnerTests {
    @Test func largeRepliesComeThroughWhole() async throws {
        // A form with a 3,000-option dropdown scans to ~340 KB; an undrained pipe (64 KB) used to stall forever.
        let big = String(repeating: "abcdefghij", count: 30_000)
        let reply = try await BrowserTab.runAppleScript("on run argv\nreturn item 1 of argv\nend run", arguments: [big], timeout: 20)
        #expect(reply.count == big.count)
    }

    @Test func aStuckCallGivesUp() async {
        let started = Date()
        await #expect {
            _ = try await BrowserTab.runAppleScript("delay 10", timeout: 1)
        } throws: { error in
            (error as? BrowserTab.ScriptError)?.timedOut == true
        }
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func cancellingStopsTheCall() async {
        let task = Task { try await BrowserTab.runAppleScript("delay 10", timeout: 30) }
        try? await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let started = Date()
        let result = await task.result
        #expect(Date().timeIntervalSince(started) < 3)
        #expect(throws: CancellationError.self) { try result.get() }
    }
}
