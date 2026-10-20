import NotchKit
import SwiftUI

/// Playlists on the left, the selected playlist's songs on the right; clicking a song plays it in that playlist.
struct PlaylistsView: View {
    let app: NowPlayingApp
    let library: SpotifyLibrary

    var body: some View {
        if !library.isSignedIn {
            VStack(spacing: 8) {
                Text("Connect Spotify to browse your playlists.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                Button("Open Settings", action: app.openSettings).controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(alignment: .top, spacing: 10) {
                playlistColumn
                    .frame(width: 190)
                Rectangle().fill(.white.opacity(0.1)).frame(width: 1)
                songColumn
            }
            .task { await app.loadPlaylistsIfNeeded() }
        }
    }

    private var playlistColumn: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 1) {
                if library.playlists.isEmpty {
                    Text(app.libraryError ?? "Loading…")
                        .font(.system(size: 11))
                        .foregroundStyle(app.libraryError == nil ? .white.opacity(0.5) : .orange)
                        .padding(6)
                }
                ForEach(library.playlists) { playlist in
                    PlaylistRow(playlist: playlist, selected: playlist.id == app.selectedPlaylistID) {
                        app.select(playlist)
                    }
                    .askable { askText(playlist) }
                }
            }
        }
    }

    @ViewBuilder
    private var songColumn: some View {
        if let playlist = app.selectedPlaylist {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(playlist.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button { app.play(nil, in: playlist) } label: {
                        Label("Play", systemImage: "play.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(.green))
                            .foregroundStyle(.black)
                    }
                    .buttonStyle(.plain)
                }
                songs(for: playlist)
            }
            .task(id: playlist.id) { app.select(playlist) }
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func songs(for playlist: SpotifyLibrary.Playlist) -> some View {
        if !library.canListSongs(playlist) {
            Text("Spotify only shares the songs of playlists you own or collaborate on. Press Play to start this one from the top.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .multilineTextAlignment(.center)
        } else if let songs = library.songs[playlist.id] {
            if songs.isEmpty {
                Text("No songs").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(songs) { song in
                            // Spotify's AppleScript reports the current track id as its URI.
                            SongRow(song: song, playing: song.uri == app.snapshot?.track?.id) {
                                app.play(song, in: playlist)
                            }
                            .askable { "Song: \(song.title)\nArtist: \(song.artist)\nFrom my Spotify playlist: \(playlist.name)" }
                        }
                    }
                }
            }
        } else {
            Text(app.libraryError ?? "Loading…")
                .font(.system(size: 11))
                .foregroundStyle(app.libraryError == nil ? .white.opacity(0.5) : .orange)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

extension PlaylistsView {
    /// Playlist name plus the first songs we know about.
    func askText(_ playlist: SpotifyLibrary.Playlist) -> String {
        var text = "My Spotify playlist: \(playlist.name)"
        if let songs = library.songs[playlist.id], !songs.isEmpty {
            text += "\nSongs:\n" + songs.prefix(40).map { "- \($0.title) — \($0.artist)" }.joined(separator: "\n")
            if songs.count > 40 { text += "\n…and \(songs.count - 40) more" }
        }
        return text
    }
}

private struct PlaylistRow: View {
    let playlist: SpotifyLibrary.Playlist
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Artwork(url: playlist.imageURL, size: 26, cornerRadius: 4)
                VStack(alignment: .leading, spacing: 0) {
                    Text(playlist.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(playlist.trackCount.map { "\($0) songs" } ?? playlist.ownerName)
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(selected ? 0.15 : hovering ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct SongRow: View {
    let song: SpotifyLibrary.Song
    let playing: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: playing ? "speaker.wave.2.fill" : "play.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(playing ? .green : .white.opacity(hovering ? 0.8 : 0))
                    .frame(width: 12)
                VStack(alignment: .leading, spacing: 0) {
                    Text(song.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(playing ? .green : .white)
                        .lineLimit(1)
                    Text(song.artist)
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(String(format: "%d:%02d", Int(song.duration) / 60, Int(song.duration) % 60))
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(hovering ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
