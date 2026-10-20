import Foundation
import Testing
@testable import NowPlayingApp

@MainActor @Suite struct SpotifyParsingTests {
    @Test func parsesPlaylistInNewAndOldShapes() throws {
        let new: [String: Any] = [
            "id": "p1", "uri": "spotify:playlist:p1", "name": "Focus", "collaborative": false,
            "images": [["url": "https://i.scdn.co/big"], ["url": "https://i.scdn.co/small"]],
            "owner": ["id": "me", "display_name": "Vaman"],
            "items": ["total": 42],
        ]
        let p = try #require(SpotifyLibrary.playlist(from: new))
        #expect(p.trackCount == 42 && p.ownerID == "me" && p.imageURL?.absoluteString == "https://i.scdn.co/small")

        var old = new
        old["items"] = nil
        old["tracks"] = ["total": 7]
        #expect(SpotifyLibrary.playlist(from: old)?.trackCount == 7)
    }

    @Test func parsesSongsInNewAndOldShapes() {
        let track: [String: Any] = [
            "uri": "spotify:track:abc", "name": "Song", "duration_ms": 200_000.0,
            "artists": [["name": "A"], ["name": "B"]], "is_local": false,
        ]
        let rows: [[String: Any]] = [
            ["item": track, "track": true],                       // Feb 2026 shape
            ["track": track],                                     // older shape
            ["item": ["uri": "spotify:episode:x", "name": "Pod"]], // podcasts skipped
            ["item": NSNull()],                                   // unavailable
        ]
        let songs = SpotifyLibrary.songs(from: rows, offset: 100)
        #expect(songs.count == 2)
        #expect(songs[0].artist == "A, B" && songs[0].duration == 200)
        #expect(songs[0].id != songs[1].id)
    }

    @Test func onlyPlainSpotifyURIsReachAppleScript() {
        #expect(SpotifyClient.isSafeURI("spotify:track:48pyUxg9RYuwie5M9R7qRn"))
        #expect(SpotifyClient.isSafeURI("spotify:playlist:37i9dQZF1DXcBWIGoYBM5M"))
        #expect(!SpotifyClient.isSafeURI("spotify:track:x\" & do shell script \"rm"))
        #expect(!SpotifyClient.isSafeURI("https://open.spotify.com/track/x"))
    }
}
