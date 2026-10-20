import SwiftUI

struct NowPlayingView: View {
    @Bindable var app: NowPlayingApp

    var body: some View {
        VStack(spacing: 6) {
            Picker("", selection: $app.tab) {
                Image(systemName: "play.circle").help("Now Playing").tag(NowPlayingApp.Tab.player)
                Image(systemName: "music.note.list").help("Playlists").tag(NowPlayingApp.Tab.playlists)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .frame(maxWidth: .infinity, alignment: .leading)

            switch app.tab {
            case .player: playerTab
            case .playlists: PlaylistsView(app: app, library: app.library)
            }
        }
    }

    private var playerTab: some View {
        Group {
            if let track = app.snapshot?.track {
                player(track)
            } else {
                VStack(spacing: 8) {
                    Text(app.isRunning ? "Nothing playing" : "Spotify isn't running")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                    if !app.isRunning {
                        Button("Open Spotify", action: app.openSpotify).controlSize(.small)
                    }
                    errorText
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await app.refresh() }
    }

    private func player(_ track: Track) -> some View {
        HStack(spacing: 16) {
            Artwork(url: track.artworkURL, size: 120, cornerRadius: 12)
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                Text(track.album)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                Spacer(minLength: 6)
                ProgressRow(app: app, duration: track.duration)
                controls
                errorText
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var controls: some View {
        HStack(spacing: 26) {
            control("backward.fill", size: 16) { app.send(.previous) }
            control(app.snapshot?.isPlaying == true ? "pause.fill" : "play.fill", size: 22) { app.send(.playPause) }
            control("forward.fill", size: 16) { app.send(.next) }
        }
        .frame(maxWidth: .infinity)
    }

    private func control(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .foregroundStyle(.white)
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var errorText: some View {
        if let error = app.error {
            Text(error).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(2)
        }
    }
}

private struct ProgressRow: View {
    let app: NowPlayingApp
    let duration: Double

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let position = app.position(at: context.date)
            HStack(spacing: 8) {
                Text(Self.format(position))
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.2))
                        Capsule().fill(.white)
                            .frame(width: duration > 0 ? geo.size.width * position / duration : 0)
                    }
                    .frame(height: 4)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        guard duration > 0 else { return }
                        app.seek(to: duration * min(max(location.x / geo.size.width, 0), 1))
                    }
                }
                .frame(height: 12)
                Text(Self.format(duration))
            }
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(.white.opacity(0.55))
        }
    }

    private static func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct Artwork: View {
    let url: URL?
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            ZStack {
                Color.white.opacity(0.1)
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.4))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

/// Little equalizer animation for the collapsed notch.
struct PlayingBars: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 12)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule()
                        .fill(.green)
                        .frame(width: 2.5, height: 4 + 9 * abs(sin(t * (3 + Double(i)) + Double(i))))
                }
            }
            .frame(height: 14)
        }
    }
}
