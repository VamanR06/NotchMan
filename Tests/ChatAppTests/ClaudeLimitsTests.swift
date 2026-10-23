import Foundation
import Testing
@testable import ChatApp

/// Exactly what `claude -p "/usage"` printed on a real machine (Pro plan).
private let realUsageOutput = """
You are currently using your subscription to power your Claude Code usage

Current session: 48% used · resets Oct 23 at 6:19am (America/Detroit)
Current week (all models): 81% used · resets Oct 23 at 5:59pm (America/Detroit)

What's contributing to your limits usage?
Approximate, based on local sessions on this machine — does not include other devices or claude.ai. Behaviors are independent characteristics, not a breakdown.

Last 24h · 331 requests · 5 sessions
  95% of your usage was at >150k context
  Top subagents: Explore 1%

Last 7d · 1177 requests · 12 sessions
  95% of your usage was at >150k context
  76% of your usage came from sessions active for 8+ hours
"""

@Suite struct ClaudeLimitsParsingTests {
    @Test func parsesTheRealOutput() {
        let limits = ClaudeLimits.parse(realUsageOutput)
        #expect(limits.planNote == "You are currently using your subscription to power your Claude Code usage")
        #expect(limits.windows.map(\.label) == ["Current session", "Current week (all models)"])
        #expect(limits.windows[0].percent == 48 && limits.windows[0].resetsText == "Oct 23 at 6:19am (America/Detroit)")
        #expect(limits.windows[1].percent == 81 && limits.windows[1].isNearLimit && !limits.windows[1].isAtLimit)

        #expect(limits.periods.map(\.label) == ["Last 24h", "Last 7d"])
        #expect(limits.periods[0].requests == 331 && limits.periods[0].sessions == 5)
        #expect(limits.periods[0].notes == ["95% of your usage was at >150k context", "Top subagents: Explore 1%"])
        #expect(limits.periods[1].requests == 1177 && limits.periods[1].sessions == 12)
    }

    @Test func thresholdsPickTheRightColorTier() {
        #expect(ClaudeLimitWindow(label: "x", percent: 50, resetsText: "").isNearLimit == false)
        #expect(ClaudeLimitWindow(label: "x", percent: 75, resetsText: "").isNearLimit)
        #expect(ClaudeLimitWindow(label: "x", percent: 89, resetsText: "").isAtLimit == false)
        #expect(ClaudeLimitWindow(label: "x", percent: 90, resetsText: "").isAtLimit)
    }

    @Test func toleratesMissingOrExtraWindows() {
        // A different plan might show three windows (e.g. a per-model week limit) or none.
        let three = ClaudeLimits.parse("""
            Current session: 10% used · resets in 3h
            Current week (Opus): 20% used · resets Mon
            Current week (all models): 30% used · resets Mon
            """)
        #expect(three.windows.count == 3)
        #expect(ClaudeLimits.parse("Usage credits are off · /usage-credits to turn them on").windows.isEmpty)
        #expect(ClaudeLimits.parse("").windows.isEmpty && ClaudeLimits.parse("").planNote == nil)
    }

    @Test func ignoresCommentaryLinesAsPlanNote() {
        // "What's contributing…" must never be mistaken for the plan note, even with no windows before it.
        let limits = ClaudeLimits.parse("What's contributing to your limits usage?\nApproximate, based on...")
        #expect(limits.planNote == nil)
    }
}

/// Runs `refreshLimits` against a stand-in `claude` so no real usage is spent.
@MainActor @Suite(.serialized) struct RefreshLimitsTests {
    private func stubClaude(output: String) throws -> (path: String, callCount: () -> Int) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "notchman-usage-stub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appending(path: "claude").path
        let calls = dir.appending(path: "calls").path
        let payload = dir.appending(path: "out.txt").path
        try output.write(toFile: payload, atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        if [ "$1" = "agents" ]; then echo '[]'; exit 0; fi
        echo x >> '\(calls)'
        cat '\(payload)'
        """.write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        return (script, { (try? String(contentsOfFile: calls, encoding: .utf8))?.split(separator: "\n").count ?? 0 })
    }

    @Test func fetchesAndCachesForTwoMinutes() async throws {
        let (path, callCount) = try stubClaude(output: realUsageOutput)
        let defaults = UserDefaults(suiteName: "notchman.tests.limits")!
        let monitor = ClaudeAgentsMonitor(defaults: defaults)
        monitor.claudePathOverride = path

        await monitor.refreshLimits()
        #expect(monitor.limits?.windows.count == 2 && monitor.limitsError == nil)
        #expect(callCount() == 1)

        await monitor.refreshLimits()  // within the cache window: no second call
        #expect(callCount() == 1)

        await monitor.refreshLimits(force: true)
        #expect(callCount() == 2)
        defaults.removeObject(forKey: "claudePath")
    }

    @Test func reportsWhenUsageFails() async throws {
        // claude exists but `-p "/usage"` fails (e.g. not signed in, or a transient error).
        let dir = FileManager.default.temporaryDirectory.appending(path: "notchman-usage-fail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appending(path: "claude").path
        try """
        #!/bin/sh
        if [ "$1" = "agents" ]; then echo '[]'; exit 0; fi
        echo "not logged in" >&2
        exit 1
        """.write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)

        let defaults = UserDefaults(suiteName: "notchman.tests.limits")!
        let monitor = ClaudeAgentsMonitor(defaults: defaults)
        monitor.claudePathOverride = script
        await monitor.refreshLimits(force: true)
        #expect(monitor.limits == nil)
        #expect(monitor.limitsError?.contains("not logged in") == true)
        defaults.removeObject(forKey: "claudePath")
    }
}
