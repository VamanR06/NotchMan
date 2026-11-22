import Foundation
import Testing
@testable import ShelfApp

@MainActor @Suite struct ShelfCommandsTests {
    @Test func offersShelvedFilesAndTheFileActions() {
        let app = ShelfApp()
        app.addToShelf([URL(fileURLWithPath: "/tmp/resume.pdf")])
        let commands = app.commands(for: "resume")
        #expect(commands.items.contains { $0.title == "resume.pdf" && $0.kind == "File" })
        #expect(Set(commands.actions.map(\.id)) == ["put_file", "open_file", "preview_file", "reveal_file", "open_folder"])
        let put = commands.actions.first { $0.id == "put_file" }!
        #expect(put.risk == .confirm, "moving files asks first")
        #expect(put.parameters.first { $0.name == "file" }?.choices.map(\.label) == ["resume.pdf"])
        #expect(put.parameters.first { $0.name == "folder" }?.choices.isEmpty == false, "places at least")
    }
}
