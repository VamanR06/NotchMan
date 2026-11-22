import AppKit
import QuickLookThumbnailing
import QuickLookUI
import SwiftUI

/// macOS's own preview of a file (PDF, image, video, Office documents, …), drawn inside a notch view.
public struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = true
        view.shouldCloseWithWindow = false
        view.previewItem = url as NSURL
        return view
    }

    public func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url { view.previewItem = url as NSURL }
    }

    public static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}

/// A file's thumbnail (its first page, the picture itself, a video frame), or its Finder icon until one is made or
/// when there's none. Thumbnails are kept in memory for the session.
public struct FileThumbnail: View {
    let url: URL
    let size: CGFloat
    @State private var image: NSImage?

    public init(url: URL, size: CGFloat) {
        self.url = url
        self.size = size
    }

    public var body: some View {
        Image(nsImage: image ?? NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .task(id: url) { image = await ThumbnailCache.shared.thumbnail(for: url, size: size) }
    }
}

@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()

    func thumbnail(for url: URL, size: CGFloat) async -> NSImage? {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let key = "\(url.path)|\(Int(size))|\(modified?.timeIntervalSince1970 ?? 0)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size), scale: scale,
                                                   representationTypes: .thumbnail)
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        else { return nil }
        let image = representation.nsImage
        cache.setObject(image, forKey: key)
        return image
    }
}

/// The full-size Quick Look window (as Space in Finder), for files in a view too small to preview them in.
@MainActor
public enum QuickLookPanel {
    private static let source = Source()

    /// Shows `urls` starting at `index`; ←/→ step through them. Toggles it closed if it's already showing them.
    public static func show(_ urls: [URL], at index: Int = 0) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible, source.urls == urls, panel.currentPreviewItemIndex == index {
            panel.orderOut(nil)
            return
        }
        source.urls = urls
        // Quick Look's window needs the keyboard (Space/Esc close it, arrows step), which needs NotchMan active;
        // focus goes back to your app once it and the notch have closed.
        NotchFocus.activateForTyping()
        panel.dataSource = source
        panel.reloadData()
        panel.currentPreviewItemIndex = min(max(index, 0), urls.count - 1)
        panel.makeKeyAndOrderFront(nil)
    }

    private final class Source: NSObject, QLPreviewPanelDataSource {
        var urls: [URL] = []

        func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

        func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
            urls[index] as NSURL
        }
    }
}
