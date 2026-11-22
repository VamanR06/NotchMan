import Foundation
import NotchKit

extension NowPlayingApp {
    public var relevance: NotchRelevance? {
        guard let snapshot, snapshot.isPlaying, let track = snapshot.track else { return nil }
        return NotchRelevance("Music playing: “\(track.title)”")
    }
}
