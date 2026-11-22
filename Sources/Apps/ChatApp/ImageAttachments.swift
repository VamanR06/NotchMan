import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Images for a message to Claude: pasted or dropped, saved as PNG files, and sent as their paths (Claude Code reads
/// image files named in a prompt, as it does when you paste an image into its terminal).
enum ImageAttachments {
    static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "NotchMan/pasted")
    }

    /// The clipboard's image, if it has one (a screenshot, a copied image — not a copied file's icon).
    static func imageOnPasteboard(_ pasteboard: NSPasteboard = .general) -> NSImage? {
        guard pasteboard.availableType(from: [.png, .tiff]) != nil else { return nil }
        return NSImage(pasteboard: pasteboard)
    }

    /// Writes the image as a PNG and returns its file.
    static func save(_ image: NSImage, folder: URL = folder) -> URL? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "image-\(Int(Date().timeIntervalSince1970 * 1000)).png")
        return (try? png.write(to: file)) == nil ? nil : file
    }

    static func isImage(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.conforms(to: .image) == true
    }

    /// What's sent: the text, then each image's path on its own line.
    static func message(_ text: String, images: [URL]) -> String {
        guard !images.isEmpty else { return text }
        let paths = images.map(\.path).joined(separator: "\n")
        return text.isEmpty ? paths : text + "\n\n" + paths
    }
}

/// Catches ⌘V while the composer has the keyboard and the clipboard holds an image (a text field can't take an image
/// itself), and hands the image over instead.
@MainActor
final class ImagePasteMonitor {
    private var monitor: Any?

    func start(isActive: @escaping @MainActor () -> Bool, onImage: @escaping @MainActor (NSImage) -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            nonisolated(unsafe) let event = event
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard event.modifierFlags.intersection([.command, .option, .shift, .control]) == .command,
                      event.charactersIgnoringModifiers?.lowercased() == "v", isActive(),
                      let image = ImageAttachments.imageOnPasteboard() else { return false }
                onImage(image)
                return true
            }
            return handled ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// The attached images above the composer, each with a way to take it off.
struct AttachmentStrip: View {
    let images: [URL]
    let remove: (URL) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(images, id: \.self) { url in
                ZStack(alignment: .topTrailing) {
                    Image(nsImage: NSImage(contentsOf: url) ?? NSImage())
                        .resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.15)))
                    Button { remove(url) } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                            .foregroundStyle(.white, .black.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 4, y: -4)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.top, 6)
    }
}
