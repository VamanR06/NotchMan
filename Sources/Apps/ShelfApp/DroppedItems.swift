import Foundation
import UniformTypeIdentifiers
import os

let shelfLog = Logger(subsystem: "com.notchman", category: "shelf")

/// Turns whatever was dragged in into files. Finder hands over file links, but many apps don't: screenshot
/// thumbnails, Mail and Messages attachments, Photos and browser images arrive as the file's contents (or a
/// promise of them). Those are written to a holding folder under their own name, then placed like any file.
enum DroppedItems {
    /// Types a drop target accepts: anything that's a file link or file contents.
    static let acceptedTypes: [UTType] = [.fileURL, .url, .data, .item]

    /// Where file contents land: moved on when dropped into a folder, kept while they sit on the Shelf. (Not the
    /// temporary folder, which macOS empties after a few days.)
    static var holdingFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "NotchMan/Dropped")
    }

    /// The files the dragged items stand for, in drop order.
    static func fileURLs(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            shelfLog.notice("Dropped item types: \(provider.registeredTypeIdentifiers.joined(separator: ", "), privacy: .public)")
            if let url = await fileLink(from: provider) {
                urls.append(url)
            } else if let url = await fileContents(from: provider) {
                urls.append(url)
            } else {
                shelfLog.error("A dropped item had neither a file link nor file contents")
            }
        }
        return urls
    }

    /// A link to a file on disk, if the item has one (Finder, the Shelf itself, most file drags).
    private static func fileLink(from provider: NSItemProvider) async -> URL? {
        guard provider.canLoadObject(ofClass: NSURL.self) else { return nil }
        let url: URL? = await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                continuation.resume(returning: (object as? NSURL) as URL?)
            }
        }
        guard let url, url.isFileURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// The item's contents as a file (for drags that carry data or a file promise instead of a link). The
    /// system hands over a temporary copy that's removed afterwards, so it's copied into the holding folder.
    private static func fileContents(from provider: NSItemProvider) async -> URL? {
        let types = provider.registeredTypeIdentifiers
        // The most specific file-like type: a real format (PNG, PDF…) rather than generic data or text links.
        guard let type = types.first(where: { id in
            guard let ut = UTType(id) else { return false }
            return ut.conforms(to: .data) && ut != .url && ut != .fileURL && !ut.conforms(to: .url)
        }) ?? types.first else { return nil }
        let suggested = provider.suggestedName
        return await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type) { temporary, error in
                guard let temporary else {
                    if let error { shelfLog.error("Couldn't read dropped contents: \(error.localizedDescription, privacy: .public)") }
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: keep(temporary, suggestedName: suggested, type: UTType(type)))
            }
        }
    }

    /// Copies a temporary file into its own holding folder under the name it should have.
    static func keep(_ temporary: URL, suggestedName: String?, type: UTType?) -> URL? {
        let fm = FileManager.default
        let folder = holdingFolder.appending(path: UUID().uuidString)
        var name = suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-") ?? ""
        if name.isEmpty { name = temporary.lastPathComponent }
        if (name as NSString).pathExtension.isEmpty, let ext = type?.preferredFilenameExtension { name += "." + ext }
        let target = folder.appending(path: name)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try fm.copyItem(at: temporary, to: target)
            return target
        } catch {
            shelfLog.error("Couldn't keep dropped contents: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
