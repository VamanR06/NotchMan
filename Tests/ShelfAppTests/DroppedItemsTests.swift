import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import ShelfApp

/// Drag items like the ones different apps hand over.
@Suite struct DroppedItemsTests {
    private func tempFile(_ name: String, _ contents: String = "hello") throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "drops-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    @Test func aFinderFileLinkIsUsedAsIs() async throws {
        let file = try tempFile("Report.pdf")
        let provider = try #require(NSItemProvider(contentsOf: file))
        let urls = await DroppedItems.fileURLs(from: [provider])
        #expect(urls.map(\.standardizedFileURL) == [file.standardizedFileURL])
    }

    @Test func contentsWithoutALinkBecomeAFileWithItsName() async throws {
        // A screenshot thumbnail or Mail attachment: PNG data and a suggested name, no file on disk.
        let png = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            .representation(using: .png, properties: [:])!
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(png, nil)
            return nil
        }
        provider.suggestedName = "Screenshot 2026-10-27"
        let urls = await DroppedItems.fileURLs(from: [provider])
        let url = try #require(urls.first)
        #expect(url.lastPathComponent == "Screenshot 2026-10-27.png")
        #expect(url.path.hasPrefix(DroppedItems.holdingFolder.path))
        #expect(try Data(contentsOf: url) == png)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    @Test func keptContentsGetAnExtensionFromTheirType() throws {
        let temporary = try tempFile("tmp-123", "%PDF")
        let kept = try #require(DroppedItems.keep(temporary, suggestedName: "Invoice", type: .pdf))
        #expect(kept.lastPathComponent == "Invoice.pdf")
        let named = try #require(DroppedItems.keep(temporary, suggestedName: "notes.txt", type: .plainText))
        #expect(named.lastPathComponent == "notes.txt")
        try? FileManager.default.removeItem(at: kept.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: named.deletingLastPathComponent())
    }
}
