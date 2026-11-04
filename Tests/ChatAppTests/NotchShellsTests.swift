import AppKit
import Foundation
import Testing
@testable import ChatApp

@Suite struct CloneDetectorTests {
    @Test func findsTheFolderGitClonesInto() {
        #expect(CloneDetector.folder(in: "Cloning into 'NotchMan'...\r") == "NotchMan")
        #expect(CloneDetector.folder(in: "Cloning into '/tmp/my repo'...") == "/tmp/my repo")
        #expect(CloneDetector.folder(in: "\u{1B}[1mCloning into 'x'...\u{1B}[0m") == "x")
    }

    @Test func ignoresBareReposAndOtherOutput() {
        #expect(CloneDetector.folder(in: "Cloning into bare repository 'x.git'...") == nil)
        #expect(CloneDetector.folder(in: "remote: Counting objects: 100% (5/5), done.") == nil)
        #expect(CloneDetector.folder(in: "echo Cloning into") == nil)
    }

    @Test func joinsLinesSplitAcrossChunks() {
        var detector = CloneDetector()
        #expect(detector.feed("$ git clone https://github.com/a/b\r\nCloning in") == [])
        #expect(detector.feed("to 'b'...") == [])
        #expect(detector.feed("\r\nremote: Enumerating objects: 5, done.\r\n") == ["b"])
        #expect(detector.feed("Receiving objects: 100% (5/5)\r\n") == [])
    }
}

@MainActor @Suite struct ShellWorkspaceTests {
    @Test func tabsOpenSelectAndCloseToANeighbour() {
        let shells = ShellWorkspace()
        var emptied = false
        shells.onEmpty = { emptied = true }
        let first = shells.add(in: NSTemporaryDirectory())
        let second = shells.add(in: NSTemporaryDirectory())
        #expect(shells.selectedTab?.id == second.id)
        shells.selected = first.id
        shells.close(first.id)
        #expect(shells.selectedTab?.id == second.id)
        #expect(!emptied)
        shells.close(second.id)
        #expect(shells.tabs.isEmpty)
        #expect(emptied)
    }

    @Test func tabsAreNamedForTheirFolder() {
        let shells = ShellWorkspace()
        let tab = shells.add(in: "/tmp")
        #expect(ShellWorkspace.title(tab) == "tmp")
        shells.closeAll()
        #expect(shells.tabs.isEmpty)
    }

    @Test func gitCloneOutputOffersTheNewFolder() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("notchman-clone-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base.appendingPathComponent("repo"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let session = TerminalSession()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 680, height: 380), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = session.view
        session.runShell(in: base.path)
        // What git prints (on stderr) as a clone starts, relative to the shell's folder.
        session.view.send(txt: "printf \"Cloning into 'repo'...\\n\" >&2\r")
        for _ in 0..<50 where session.clonedFolder == nil { try await Task.sleep(for: .milliseconds(100)) }
        let expected = base.appendingPathComponent("repo").standardizedFileURL.path
        #expect(session.clonedFolder.map { $0.replacingOccurrences(of: "/private/var", with: "/var") }
                == expected.replacingOccurrences(of: "/private/var", with: "/var"))
        session.stop()
        _ = window
    }
}
