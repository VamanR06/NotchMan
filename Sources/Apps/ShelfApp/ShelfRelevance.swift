import Foundation
import NotchKit

extension ShelfApp {
    public var relevance: NotchRelevance? {
        if let download = activeDownloads.first {
            return NotchRelevance("Downloading a file" + (download.fraction.map { " (\(Int($0 * 100))%)" } ?? ""))
        }
        if !commands.isEmpty { return NotchRelevance("\(commands.count) long-running terminal command(s) in progress") }
        return items.isEmpty ? nil : NotchRelevance("\(items.count) file(s) kept on the shelf")
    }
}
