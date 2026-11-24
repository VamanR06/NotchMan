import Foundation
import Testing
@testable import ChatApp

@Suite struct ClaudeTrustTests {
    private func projects(_ data: Data?) -> [String: Any] {
        guard let data, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return root["projects"] as? [String: Any] ?? [:]
    }

    @Test func trustsANewFolderAndKeepsTheRest() {
        let config = Data(#"{"numStartups":3,"projects":{"/a":{"allowedTools":["Bash"],"hasTrustDialogAccepted":false}}}"#.utf8)
        let updated = ClaudeTrust.trusting("/a", in: config)
        let a = projects(updated)["/a"] as? [String: Any]
        #expect(a?["hasTrustDialogAccepted"] as? Bool == true)
        #expect(a?["allowedTools"] as? [String] == ["Bash"])
        let root = updated.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        #expect(root?["numStartups"] as? Int == 3)

        let b = projects(ClaudeTrust.trusting("/b/c/", in: config))["/b/c"] as? [String: Any]
        #expect(b?["hasTrustDialogAccepted"] as? Bool == true)
    }

    @Test func leavesTrustedFoldersAlone() {
        let config = Data(#"{"projects":{"/Users/me":{"hasTrustDialogAccepted":true}}}"#.utf8)
        #expect(ClaudeTrust.trusting("/Users/me", in: config) == nil)
        // Under a trusted folder counts as trusted, as in Claude Code.
        #expect(ClaudeTrust.trusting("/Users/me/new-project", in: config) == nil)
        #expect(ClaudeTrust.trusting("/x", in: Data("not json".utf8)) == nil)
    }

    @Test func writesTheConfigFile() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "notchman-trust-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = dir.appending(path: ".claude.json")
        try Data("{}".utf8).write(to: config)
        ClaudeTrust.trust("/new/folder", config: config)
        let p = projects(try Data(contentsOf: config))["/new/folder"] as? [String: Any]
        #expect(p?["hasTrustDialogAccepted"] as? Bool == true)
    }
}
