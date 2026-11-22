import AppKit
import Testing
@testable import ChatApp

@MainActor @Suite struct ImageAttachmentsTests {
    private func image() -> NSImage {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        return image
    }

    @Test func aPastedImageIsSavedAsAPNG() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "paste-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try #require(ImageAttachments.save(image(), folder: folder))
        #expect(file.pathExtension == "png" && ImageAttachments.isImage(file))
        #expect(NSImage(contentsOf: file) != nil)
    }

    @Test func theClipboardsImageIsFound() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("notchman.tests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("just text", forType: .string)
        #expect(ImageAttachments.imageOnPasteboard(pasteboard) == nil, "text isn't an image")
        pasteboard.clearContents()
        pasteboard.writeObjects([image()])
        #expect(ImageAttachments.imageOnPasteboard(pasteboard) != nil)
        pasteboard.releaseGlobally()
    }

    @Test func imagesGoAfterTheTextAsPaths() {
        let a = URL(fileURLWithPath: "/tmp/a.png"), b = URL(fileURLWithPath: "/tmp/b.png")
        #expect(ImageAttachments.message("what's wrong here?", images: [a, b]) == "what's wrong here?\n\n/tmp/a.png\n/tmp/b.png")
        #expect(ImageAttachments.message("", images: [a]) == "/tmp/a.png", "an image alone is enough")
        #expect(ImageAttachments.message("hi", images: []) == "hi")
    }
}
