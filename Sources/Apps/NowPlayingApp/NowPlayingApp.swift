import AppKit
import SwiftUI
import NotchKit

/// Shows and controls what's playing in Spotify.
@MainActor @Observable
public final class NowPlayingApp: NotchApp {
    public let id = "nowplaying"
    public let name = "Now Playing"
    public let iconSystemName = "music.note"
    public var expandedHeight: CGFloat { 200 }

    enum Tab: Hashable { case player, playlists }
    var tab: Tab = .player
    var selectedPlaylistID: String?
    private(set) var libraryError: String?

    private(set) var isRunning = false
    private(set) var snapshot: PlayerSnapshot?
    /// When `snapshot.position` was sampled, for interpolating progress.
    private(set) var sampledAt = Date()
    private(set) var error: String?

    @ObservationIgnored private var context: NotchContext?
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private(set) var library: SpotifyLibrary!

    public init() {}

    public func activate(context: NotchContext) {
        self.context = context
        library = SpotifyLibrary(keychain: context.keychain, defaults: context.defaults)
        isRunning = SpotifyClient.isRunning

        // Spotify broadcasts this on every play/pause/track change.
        let distributed = DistributedNotificationCenter.default()
        observers.append((distributed, distributed.addObserver(
            forName: Notification.Name("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSoon() }
        }))

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append((workspace, workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == SpotifyClient.bundleID else { return }
                MainActor.assumeIsolated { self?.refreshSoon() }
            }))
        }

        // Spotify announces play/pause/track changes itself, so polling only keeps the position bar in sync: it
        // asks Spotify only while a track plays with Now Playing on screen.
        refreshSoon()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                if self.snapshot?.isPlaying == true, self.context?.isVisible == true { await self.refresh() }
            }
        }
    }

    /// Catches up on the position (not polled while the notch is closed) as the notch opens.
    public func notchWillOpen() {
        if isRunning { refreshSoon() }
    }

    public func deactivate() {
        poller?.cancel()
        observers.forEach { center, token in center.removeObserver(token) }
        observers.removeAll()
    }

    private func refreshSoon() {
        Task { await refresh() }
    }

    func refresh() async {
        isRunning = SpotifyClient.isRunning
        guard isRunning else {
            snapshot = nil
            return
        }
        do {
            let new = try await SpotifyClient.snapshot()
            snapshot = new
            sampledAt = Date()
            error = nil
            isRunning = new != nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func send(_ command: SpotifyClient.Command) {
        Task {
            do { try await SpotifyClient.send(command) } catch { self.error = error.localizedDescription }
            await refresh()
        }
    }

    func seek(to seconds: Double) {
        Task {
            try? await SpotifyClient.seek(to: seconds)
            await refresh()
        }
    }

    func openSpotify() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: SpotifyClient.bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    /// Current position, interpolated between polls while playing.
    func position(at date: Date) -> Double {
        guard let snapshot, let track = snapshot.track else { return 0 }
        let elapsed = snapshot.isPlaying ? date.timeIntervalSince(sampledAt) : 0
        return min(snapshot.position + elapsed, track.duration)
    }

    /// On top: artwork left of the notch, playing bars right of it. Otherwise a chip with both.
    public var activity: NotchActivity? {
        guard let snapshot, snapshot.isPlaying, let track = snapshot.track else { return nil }
        return NotchActivity(priority: 10) {
            Artwork(url: track.artworkURL, size: 20, cornerRadius: 5)
        } trailing: {
            PlayingBars()
        } chip: {
            HStack(spacing: 5) {
                Artwork(url: track.artworkURL, size: 16, cornerRadius: 4)
                PlayingBars()
            }
        }
    }

    // MARK: - Playlists

    var selectedPlaylist: SpotifyLibrary.Playlist? {
        library.playlists.first { $0.id == selectedPlaylistID }
    }

    func loadPlaylistsIfNeeded() async {
        guard library.isSignedIn, library.playlists.isEmpty else { return }
        await loadPlaylists()
    }

    func loadPlaylists() async {
        do {
            try await library.loadPlaylists()
            libraryError = nil
            if selectedPlaylistID == nil { selectedPlaylistID = library.playlists.first?.id }
        } catch {
            libraryError = error.localizedDescription
        }
    }

    func select(_ playlist: SpotifyLibrary.Playlist) {
        selectedPlaylistID = playlist.id
        guard library.songs[playlist.id] == nil else { return }
        Task {
            do { try await library.loadSongs(for: playlist); libraryError = nil } catch { libraryError = error.localizedDescription }
        }
    }

    /// Plays a song within its playlist, or the whole playlist from the top when `song` is nil.
    func play(_ song: SpotifyLibrary.Song?, in playlist: SpotifyLibrary.Playlist) {
        let previous = NSWorkspace.shared.frontmostApplication
        let spotifyBefore = NSRunningApplication.runningApplications(withBundleIdentifier: SpotifyClient.bundleID).first
        let spotifyWasVisible = spotifyBefore.map { !$0.isHidden } ?? false
        Task {
            do {
                if let song {
                    try await SpotifyClient.play(song.uri, context: playlist.uri)
                } else {
                    try await SpotifyClient.play(playlist.uri)
                }
                error = nil
                await Self.restoreFocus(to: previous, spotifyWasVisible: spotifyWasVisible)
            } catch {
                self.error = error.localizedDescription
            }
            try? await Task.sleep(for: .milliseconds(400))
            await refresh()
        }
    }

    /// Spotify's `play track` brings its window to the front — sometimes more than a second later, and sometimes
    /// twice (again once playback starts). For a few seconds, whenever it comes forward, hand focus back to
    /// the app the user was in. If macOS refuses that activation, hide Spotify instead: when the frontmost app
    /// hides, focus returns to the app beneath it. A window that was showing before is unhidden afterwards,
    /// which doesn't take focus.
    private static func restoreFocus(to previous: NSRunningApplication?, spotifyWasVisible: Bool) async {
        guard let previous, previous.bundleIdentifier != SpotifyClient.bundleID else { return }
        func spotifyIsFront() -> NSRunningApplication? {
            let front = NSWorkspace.shared.frontmostApplication
            return front?.bundleIdentifier == SpotifyClient.bundleID ? front : nil
        }

        var hidden: NSRunningApplication?
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            guard let spotify = spotifyIsFront() else { continue }
            previous.activate()
            try? await Task.sleep(for: .milliseconds(300))
            if spotifyIsFront() != nil {
                spotify.hide()
                hidden = spotify
            }
        }

        guard let hidden, spotifyWasVisible else { return }
        hidden.unhide()
        try? await Task.sleep(for: .milliseconds(250))
        // Unhiding shouldn't take focus; if it did anyway, leaving Spotify hidden beats stealing focus.
        if spotifyIsFront() != nil { hidden.hide() }
    }

    func openSettings() {
        context?.openSettings()
    }

    public func makeSettingsView() -> AnyView? {
        AnyView(NowPlayingSettingsView(app: self, library: library))
    }

    public func makeExpandedView() -> AnyView {
        AnyView(NowPlayingView(app: self))
    }
}
