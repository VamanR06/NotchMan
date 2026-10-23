import Foundation
import Testing
@testable import ShelfApp

@Suite struct ProjectDropTests {
    private func makeProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "shelf-\(UUID().uuidString)/my-app")
        let fm = FileManager.default
        for folder in ["src/assets", "node_modules/x", ".git", "docs", "build", "App.xcodeproj"] {
            try fm.createDirectory(at: root.appending(path: folder), withIntermediateDirectories: true)
        }
        try Data("x".utf8).write(to: root.appending(path: "README.md"))
        return root
    }

    @Test func offersOnlyUsefulSubfolders() throws {
        let root = try makeProject()
        // .xcodeproj is a package; hidden and generated folders are skipped; files aren't folders.
        #expect(ProjectDrop.subfolders(of: root).map(\.lastPathComponent) == ["docs", "src"])
        #expect(ProjectDrop.subfolders(of: root.appending(path: "src")).map(\.lastPathComponent) == ["assets"])
    }

    @Test func clashesGetFinderStyleNames() throws {
        let root = try makeProject()
        let readme = root.appending(path: "README.md")
        let target = ProjectDrop.target(for: URL(fileURLWithPath: "/elsewhere/README.md"), in: root)
        #expect(target.exists && target.url.lastPathComponent == "README.md")
        #expect(ProjectDrop.freeName(for: readme).lastPathComponent == "README 2.md")
        try Data().write(to: root.appending(path: "README 2.md"))
        #expect(ProjectDrop.freeName(for: readme).lastPathComponent == "README 3.md")
        #expect(ProjectDrop.freeName(for: root.appending(path: "docs")).lastPathComponent == "docs 2")
        #expect(ProjectDrop.freeName(for: root.appending(path: "new.txt")).lastPathComponent == "new.txt")
    }

    @Test func referencesAreProjectRelative() {
        let root = URL(fileURLWithPath: "/Users/me/my-app")
        #expect(ProjectDrop.reference(for: root.appending(path: "src/assets/logo.png"), in: root) == "@src/assets/logo.png")
        #expect(ProjectDrop.reference(for: root.appending(path: "notes.md"), in: root) == "@notes.md")
        #expect(ProjectDrop.reference(for: root.appending(path: "My Docs/spec v2.pdf"), in: root) == "@\"My Docs/spec v2.pdf\"")
        #expect(ProjectDrop.label(for: root.appending(path: "src/assets"), in: root) == "my-app/src/assets")
        #expect(ProjectDrop.label(for: root, in: root) == "my-app")
    }
}

@Suite struct DownloadsTests {
    @Test func partialDownloadsAreRecognized() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(count: 10).write(to: folder.appending(path: "report.pdf"))
        try Data(count: 20).write(to: folder.appending(path: "movie.mp4.crdownload"))
        try FileManager.default.createDirectory(at: folder.appending(path: "big.zip.download"), withIntermediateDirectories: true)
        try Data(count: 30).write(to: folder.appending(path: "big.zip.download/big.zip"))

        let items = DownloadsFolder.list(in: folder)
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })
        #expect(byName["report.pdf"]?.isInProgress == false)
        #expect(byName["movie.mp4"]?.isInProgress == true)
        #expect(byName["big.zip"]?.isInProgress == true)
        #expect(byName["big.zip"]?.size == 30)
    }

    @Test func runScriptReportsStartAndExitStatus() {
        #expect(NotchmanRun.script.contains("\"state\\\":\\\"start\\\"") || NotchmanRun.script.contains(#"\"state\":\"start\""#))
        #expect(NotchmanRun.script.contains("exit $STATUS"))
        #expect(NotchmanRun.script.hasPrefix("#!/bin/sh"))
    }

    @Test func runScriptRunsTheCommandAndKeepsItsStatus() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "notchman-run-\(UUID().uuidString)")
        try Data(NotchmanRun.script.utf8).write(to: file)
        func run(_ args: [String]) throws -> (Int32, String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            // No token file in this fake home, so it just runs the command.
            process.environment = ["HOME": FileManager.default.temporaryDirectory.path, "PATH": "/usr/bin:/bin"]
            process.arguments = [file.path] + args
            let out = Pipe()
            process.standardOutput = out
            try process.run()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
        let (ok, output) = try run(["echo", "hi \"there\""])
        #expect(ok == 0 && output == "hi \"there\"\n")
        let (failed, _) = try run(["sh", "-c", "exit 3"])
        #expect(failed == 3)
    }
}
