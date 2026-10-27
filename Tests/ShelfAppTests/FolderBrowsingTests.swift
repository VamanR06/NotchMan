import Foundation
import Testing
import NotchKit
@testable import ShelfApp

@MainActor @Suite(.serialized) struct FolderBrowsingTests {
    private func makeFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "browse-\(UUID().uuidString)")
        let fm = FileManager.default
        for folder in ["Assets", "node_modules", "build", ".git", "Docs"] {
            try fm.createDirectory(at: root.appending(path: folder), withIntermediateDirectories: true)
        }
        for file in ["notes.md", "Logo.png", ".DS_Store"] { try Data().write(to: root.appending(path: file)) }
        return root
    }

    @Test func listsFoldersAndFilesHidingBuildFoldersOnlyInProjects() throws {
        let root = try makeFolder()
        let anywhere = ProjectDrop.entries(of: root, hidingBuildFolders: false)
        #expect(anywhere.folders.map(\.lastPathComponent) == ["Assets", "build", "Docs", "node_modules"])
        #expect(anywhere.files.map(\.lastPathComponent) == ["Logo.png", "notes.md"])
        let project = ProjectDrop.entries(of: root, hidingBuildFolders: true)
        #expect(project.folders.map(\.lastPathComponent) == ["Assets", "Docs"])
    }

    @Test func filterMatchesNamesCaseInsensitively() throws {
        let root = try makeFolder()
        let hits = ProjectDrop.entries(of: root, hidingBuildFolders: false, matching: "do")
        #expect(hits.folders.map(\.lastPathComponent) == ["Docs"])
        #expect(hits.files.isEmpty)
        #expect(ProjectDrop.entries(of: root, hidingBuildFolders: false, matching: "LOGO").files.count == 1)
    }

    @Test func ancestorsGoAllTheWayUp() {
        let path = ProjectDrop.ancestors(of: URL(fileURLWithPath: "/Users/me/code/app")).map(\.path)
        #expect(path == ["/Users/me/code/app", "/Users/me/code", "/Users/me", "/Users", "/"])
    }

    @Test func pathsReadRelativeToProjectOrHome() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(ProjectDrop.displayPath(home.appending(path: "Desktop/Stuff"), project: nil) == "~/Desktop/Stuff")
        #expect(ProjectDrop.displayPath(URL(fileURLWithPath: "/tmp/x"), project: nil) == "/tmp/x")
        let project = BoardProjectRef(cwd: "/Users/me/code/app")
        #expect(ProjectDrop.displayPath(URL(fileURLWithPath: "/Users/me/code/app/src"), project: project) == "app/src")
    }

    @Test func recentsAreNewestFirstWithoutRepeatsAndCapped() throws {
        let defaults = try #require(UserDefaults(suiteName: "test.recents.\(UUID().uuidString)"))
        for i in 0..<10 { RecentFolders.add(URL(fileURLWithPath: "/f\(i)"), to: defaults) }
        RecentFolders.add(URL(fileURLWithPath: "/f3"), to: defaults)
        let paths = RecentFolders.load(defaults).map(\.path)
        #expect(paths.count == RecentFolders.limit)
        #expect(paths.first == "/f3")
        #expect(paths.filter { $0 == "/f3" }.count == 1)
        RecentFolders.remove(URL(fileURLWithPath: "/f3"), from: defaults)
        #expect(!RecentFolders.load(defaults).map(\.path).contains("/f3"))
    }

    @Test func aFolderKnowsItsDeepestProject() {
        NotchBoard.shared.publishProjects([
            BoardProject(name: "outer", cwd: "/Users/me/code"),
            BoardProject(name: "inner", cwd: "/Users/me/code/app"),
        ])
        defer { NotchBoard.shared.publishProjects([]) }
        let app = ShelfApp()
        #expect(app.project(containing: URL(fileURLWithPath: "/Users/me/code/app/src"))?.name == "inner")
        #expect(app.project(containing: URL(fileURLWithPath: "/Users/me/code/other"))?.name == "outer")
        #expect(app.project(containing: URL(fileURLWithPath: "/Users/me/code-old")) == nil)
        #expect(app.project(containing: URL(fileURLWithPath: "/Users/me/Desktop")) == nil)
    }
}
