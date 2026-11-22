@testable import ChatApp
import Foundation
import Testing

/// Commands saved per project, shown as buttons in its sessions.
@MainActor @Suite struct QuickCommandsTests {
    private func store() -> QuickCommands {
        let defaults = UserDefaults(suiteName: "notchman.tests.quick.\(UUID().uuidString)")!
        return QuickCommands(defaults: defaults)
    }

    @Test func savedPerProjectWithoutDuplicates() {
        let quick = store()
        quick.add("make run", for: "/Users/me/GitHub/NotchMan")
        quick.add("  make run ", for: "/Users/me/GitHub/NotchMan")
        quick.add("swift test", for: "/Users/me/GitHub/NotchMan")
        quick.add("npm run dev", for: "/Users/me/GitHub/JobManager")
        #expect(quick.commands(for: "/Users/me/GitHub/NotchMan") == ["make run", "swift test"])
        #expect(quick.commands(for: "/Users/me/GitHub/JobManager") == ["npm run dev"])
    }

    @Test func worktreesShareTheirRepositorysList() {
        let quick = store()
        quick.add("make run", for: "/Users/me/GitHub/NotchMan/.claude/worktrees/notch-fixes")
        #expect(quick.commands(for: "/Users/me/GitHub/NotchMan") == ["make run"])
        #expect(quick.commands(for: "/Users/me/GitHub/NotchMan/.claude/worktrees/other/") == ["make run"])
    }

    @Test func removingAndPersisting() {
        let defaults = UserDefaults(suiteName: "notchman.tests.quick.\(UUID().uuidString)")!
        let quick = QuickCommands(defaults: defaults)
        quick.add("make run", for: "/p")
        quick.add("make test", for: "/p")
        quick.remove("make run", for: "/p")
        #expect(QuickCommands(defaults: defaults).commands(for: "/p") == ["make test"])
        quick.remove("make test", for: "/p")
        #expect(QuickCommands(defaults: defaults).byProject.isEmpty)
    }
}
