import AppKit
import NotchKit

/// The user's playlists via Spotify's Web API (read-only). Playback itself goes through the desktop app
/// (`SpotifyClient`), so only listing needs the API.
///
/// Since Feb 2026 a Development Mode app works only if its owner has Premium, and Spotify returns the songs
/// of a playlist only when the user owns or collaborates on it; other playlists can still be played whole.
@MainActor @Observable
final class SpotifyLibrary {
    struct Playlist: Identifiable, Hashable {
        let id: String
        let name: String
        let uri: String
        let imageURL: URL?
        let ownerName: String
        let ownerID: String
        let collaborative: Bool
        let trackCount: Int?
    }

    struct Song: Identifiable, Hashable {
        /// Position-qualified so duplicate songs in a playlist stay distinct.
        let id: String
        let uri: String
        let title: String
        let artist: String
        let duration: Double
    }

    enum LibraryError: LocalizedError {
        case missingClientID, notSignedIn, authFailed(String), http(Int, String)

        var errorDescription: String? {
            switch self {
            case .missingClientID: "Enter your Spotify app's Client ID first."
            case .notSignedIn: "Not connected to Spotify."
            case .authFailed(let message): "Spotify sign-in failed: \(message)"
            case .http(403, _): "Spotify refused the request. The developer app's owner needs Premium, and your account must be added under User Management."
            case .http(let code, let body): "Spotify API error \(code): \(body.prefix(160))"
            }
        }
    }

    /// Fixed so it can be registered exactly in the Spotify developer dashboard.
    static let redirectPort: UInt16 = 43821
    static let redirectURI = "http://127.0.0.1:\(redirectPort)/callback"
    private static let scopes = "playlist-read-private playlist-read-collaborative"

    private(set) var isSignedIn: Bool
    private(set) var isSigningIn = false
    private(set) var playlists: [Playlist] = []
    private(set) var songs: [String: [Song]] = [:]
    /// Playlist IDs whose songs Spotify won't share (not owned / collaborative).
    private(set) var restricted: Set<String> = []
    private(set) var userID: String?

    @ObservationIgnored private let keychain: Keychain
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var accessToken: String?
    @ObservationIgnored private var accessTokenExpiry = Date.distantPast
    @ObservationIgnored private var pendingServer: LoopbackServer?

    init(keychain: Keychain, defaults: UserDefaults) {
        self.keychain = keychain
        self.defaults = defaults
        isSignedIn = keychain.string(for: "spotify.refreshToken") != nil
    }

    var clientID: String {
        get { defaults.string(forKey: "spotify.clientID") ?? "" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "spotify.clientID") }
    }

    // MARK: - OAuth (authorization code + PKCE, no client secret)

    func signIn() async throws {
        let clientID = self.clientID
        guard !clientID.isEmpty else { throw LibraryError.missingClientID }
        isSigningIn = true
        defer { isSigningIn = false; pendingServer = nil }

        let server = try LoopbackServer(port: Self.redirectPort)
        pendingServer = server
        _ = try await server.start()
        let pkce = PKCE()
        let state = PKCE.randomString(length: 24)

        var auth = URLComponents(string: "https://accounts.spotify.com/authorize")!
        auth.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "scope", value: Self.scopes),
            .init(name: "state", value: state),
        ]
        NSWorkspace.shared.open(auth.url!)

        let timeout = Task { try await Task.sleep(for: .seconds(300)); server.cancel() }
        defer { timeout.cancel() }
        let callback = try await server.waitForCallback()

        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        if let error = value("error") { throw LibraryError.authFailed(error) }
        guard value("state") == state, let code = value("code") else { throw LibraryError.authFailed("invalid callback") }

        try await tokenRequest([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI,
            "client_id": clientID,
            "code_verifier": pkce.verifier,
        ])
        isSignedIn = true
        try await loadPlaylists()
    }

    func cancelSignIn() {
        pendingServer?.cancel()
    }

    func signOut() {
        keychain.remove("spotify.refreshToken")
        accessToken = nil
        isSignedIn = false
        playlists = []
        songs = [:]
        restricted = []
        userID = nil
    }

    private func tokenRequest(_ form: [String: String]) async throws {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((body.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 200, let token = json["access_token"] as? String else {
            throw LibraryError.authFailed(json["error_description"] as? String ?? json["error"] as? String ?? "HTTP \(status)")
        }
        accessToken = token
        accessTokenExpiry = Date().addingTimeInterval((json["expires_in"] as? Double ?? 3600) - 60)
        // Spotify may rotate the refresh token.
        if let refresh = json["refresh_token"] as? String { keychain.set(refresh, for: "spotify.refreshToken") }
    }

    private func validAccessToken() async throws -> String {
        if let accessToken, Date() < accessTokenExpiry { return accessToken }
        guard let refresh = keychain.string(for: "spotify.refreshToken") else { throw LibraryError.notSignedIn }
        do {
            try await tokenRequest(["grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientID])
        } catch LibraryError.authFailed(let message) where message.lowercased().contains("revoked") || message.contains("invalid_grant") {
            signOut()
            throw LibraryError.notSignedIn
        }
        return accessToken ?? ""
    }

    // MARK: - API

    private func get(_ path: String, query: [URLQueryItem] = []) async throws -> (json: [String: Any], status: Int) {
        var components = URLComponents(string: "https://api.spotify.com/v1" + path)!
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(try await validAccessToken())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (json, status)
    }

    private func getOK(_ path: String, query: [URLQueryItem] = []) async throws -> [String: Any] {
        let (json, status) = try await get(path, query: query)
        guard status == 200 else { throw LibraryError.http(status, (json["error"] as? [String: Any])?["message"] as? String ?? "") }
        return json
    }

    func loadPlaylists() async throws {
        if userID == nil { userID = try await getOK("/me")["id"] as? String }
        var found: [Playlist] = []
        var offset = 0
        while offset < 500 {
            let page = try await getOK("/me/playlists", query: [.init(name: "limit", value: "50"), .init(name: "offset", value: "\(offset)")])
            let items = page["items"] as? [[String: Any]] ?? []
            found += items.compactMap(Self.playlist(from:))
            if page["next"] is NSNull || page["next"] == nil || items.isEmpty { break }
            offset += items.count
        }
        playlists = found
    }

    /// Whether Spotify will return this playlist's songs to us.
    func canListSongs(_ playlist: Playlist) -> Bool {
        !restricted.contains(playlist.id) && (playlist.collaborative || playlist.ownerID == userID || userID == nil)
    }

    func loadSongs(for playlist: Playlist) async throws {
        guard canListSongs(playlist) else { return }
        var found: [Song] = []
        var offset = 0
        // New endpoint first; older apps may still be on /tracks.
        var path = "/playlists/\(playlist.id)/items"
        while offset < 1000 {
            let query: [URLQueryItem] = [.init(name: "limit", value: "100"), .init(name: "offset", value: "\(offset)")]
            var (page, status) = try await get(path, query: query)
            if status == 404, path.hasSuffix("/items"), offset == 0 {
                path = "/playlists/\(playlist.id)/tracks"
                (page, status) = try await get(path, query: query)
            }
            if status == 403 {
                restricted.insert(playlist.id)
                return
            }
            guard status == 200 else { throw LibraryError.http(status, "") }
            let items = page["items"] as? [[String: Any]] ?? []
            found += Self.songs(from: items, offset: offset)
            if page["next"] is NSNull || page["next"] == nil || items.isEmpty { break }
            offset += items.count
        }
        songs[playlist.id] = found
    }

    // MARK: - Parsing (handles both pre- and post-Feb-2026 field names)

    static func playlist(from json: [String: Any]) -> Playlist? {
        guard let id = json["id"] as? String, let uri = json["uri"] as? String else { return nil }
        let images = json["images"] as? [[String: Any]] ?? []
        let owner = json["owner"] as? [String: Any] ?? [:]
        let counts = (json["items"] ?? json["tracks"]) as? [String: Any]
        return Playlist(
            id: id,
            name: json["name"] as? String ?? "Untitled",
            uri: uri,
            imageURL: (images.last?["url"] as? String).flatMap(URL.init(string:)),
            ownerName: owner["display_name"] as? String ?? "",
            ownerID: owner["id"] as? String ?? "",
            collaborative: json["collaborative"] as? Bool ?? false,
            trackCount: counts?["total"] as? Int
        )
    }

    static func songs(from items: [[String: Any]], offset: Int) -> [Song] {
        items.enumerated().compactMap { index, row in
            // New shape: row["item"] is the track and row["track"] is a Bool; old shape: row["track"] is the track.
            guard let track = (row["item"] as? [String: Any]) ?? (row["track"] as? [String: Any]),
                  let uri = track["uri"] as? String,
                  uri.hasPrefix("spotify:track:"),
                  track["is_local"] as? Bool != true else { return nil }
            let artists = (track["artists"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            return Song(
                id: "\(offset + index):\(uri)",
                uri: uri,
                title: track["name"] as? String ?? "Unknown",
                artist: artists.joined(separator: ", "),
                duration: (track["duration_ms"] as? Double ?? 0) / 1000
            )
        }
    }
}
