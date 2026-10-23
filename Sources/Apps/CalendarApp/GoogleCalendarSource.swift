import AppKit
import NotchKit
import SwiftUI

/// Google Calendar via the free Calendar API v3, using OAuth 2.0 (loopback redirect + PKCE)
/// with the user's own "Desktop app" OAuth client.
@MainActor @Observable
final class GoogleCalendarSource {
    struct CalendarInfo: Identifiable, Hashable {
        let id: String
        let name: String
        let color: Color
        let isPrimary: Bool
        /// Google's access role: owner / writer can change events; reader / freeBusyReader can't.
        let accessRole: String

        var canEdit: Bool { accessRole == "owner" || accessRole == "writer" }
    }

    enum GoogleError: LocalizedError {
        case missingClient, notSignedIn, authFailed(String), http(Int, String)

        var errorDescription: String? {
            switch self {
            case .missingClient: "Enter your Google OAuth client ID and secret first."
            case .notSignedIn: "Not signed in to Google."
            case .authFailed(let message): "Google sign-in failed: \(message)"
            case .http(let code, let body): "Google API error \(code): \(body.prefix(200))"
            }
        }
    }

    /// Read calendars and events, and change events (for rescheduling).
    private static let scope = "https://www.googleapis.com/auth/calendar.readonly https://www.googleapis.com/auth/calendar.events"
    private static let eventsScope = "https://www.googleapis.com/auth/calendar.events"

    /// Whether the signed-in grant allows changing events (sign-ins before rescheduling existed are read-only).
    var canEditEvents: Bool {
        let granted = (defaults.string(forKey: "google.scopes") ?? "").split(separator: " ").map(String.init)
        return granted.contains(Self.eventsScope) || granted.contains("https://www.googleapis.com/auth/calendar")
    }

    private(set) var calendars: [CalendarInfo] = []
    private(set) var isSigningIn = false
    private(set) var isSignedIn: Bool
    var hiddenCalendarIDs: Set<String> {
        didSet { defaults.set(Array(hiddenCalendarIDs), forKey: "google.hiddenCalendars") }
    }

    @ObservationIgnored private let keychain: Keychain
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var accessToken: String?
    @ObservationIgnored private var accessTokenExpiry = Date.distantPast
    @ObservationIgnored private var pendingServer: LoopbackServer?

    init(keychain: Keychain, defaults: UserDefaults) {
        self.keychain = keychain
        self.defaults = defaults
        self.isSignedIn = keychain.string(for: "google.refreshToken") != nil
        self.hiddenCalendarIDs = Set(defaults.stringArray(forKey: "google.hiddenCalendars") ?? [])
    }

    // MARK: - Client credentials

    var clientID: String {
        get { keychain.string(for: "google.clientID") ?? "" }
        set { keychain.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), for: "google.clientID") }
    }

    var clientSecret: String {
        get { keychain.string(for: "google.clientSecret") ?? "" }
        set { keychain.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), for: "google.clientSecret") }
    }

    // MARK: - OAuth

    func signIn() async throws {
        let clientID = self.clientID, clientSecret = self.clientSecret
        guard !clientID.isEmpty, !clientSecret.isEmpty else { throw GoogleError.missingClient }
        isSigningIn = true
        defer { isSigningIn = false; pendingServer = nil }

        let server = try LoopbackServer()
        pendingServer = server
        let port = try await server.start()
        let redirectURI = "http://127.0.0.1:\(port)"
        let pkce = PKCE()
        let state = PKCE.randomString(length: 24)

        var auth = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        auth.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Self.scope),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]
        NSWorkspace.shared.open(auth.url!)

        // Give up after 5 minutes.
        let timeout = Task { try await Task.sleep(for: .seconds(300)); server.cancel() }
        defer { timeout.cancel() }
        let callback = try await server.waitForCallback()

        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        if let error = value("error") { throw GoogleError.authFailed(error) }
        guard value("state") == state, let code = value("code") else {
            throw GoogleError.authFailed("invalid callback")
        }

        let tokens = try await tokenRequest([
            "code": code,
            "client_id": clientID,
            "client_secret": clientSecret,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": pkce.verifier,
        ])
        guard let refresh = tokens.refresh_token else {
            throw GoogleError.authFailed("no refresh token returned")
        }
        keychain.set(refresh, for: "google.refreshToken")
        store(tokens)
        isSignedIn = true
        try await loadCalendars()
    }

    func cancelSignIn() {
        pendingServer?.cancel()
    }

    func signOut() {
        keychain.remove("google.refreshToken")
        defaults.removeObject(forKey: "google.scopes")
        accessToken = nil
        calendars = []
        isSignedIn = false
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Double
        let refresh_token: String?
        /// Space-separated scopes Google actually granted.
        let scope: String?
    }

    private func tokenRequest(_ form: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((body.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw GoogleError.authFailed(String(data: data, encoding: .utf8) ?? "HTTP \(status)")
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private func store(_ tokens: TokenResponse) {
        accessToken = tokens.access_token
        accessTokenExpiry = Date().addingTimeInterval(tokens.expires_in - 60)
        if let scope = tokens.scope { defaults.set(scope, forKey: "google.scopes") }
    }

    private func validAccessToken() async throws -> String {
        if let accessToken, Date() < accessTokenExpiry { return accessToken }
        guard let refresh = keychain.string(for: "google.refreshToken") else { throw GoogleError.notSignedIn }
        do {
            let tokens = try await tokenRequest([
                "client_id": clientID,
                "client_secret": clientSecret,
                "refresh_token": refresh,
                "grant_type": "refresh_token",
            ])
            store(tokens)
            return tokens.access_token
        } catch GoogleError.authFailed(let message) where message.contains("invalid_grant") {
            // Refresh token revoked or expired: require a fresh sign-in.
            signOut()
            throw GoogleError.notSignedIn
        }
    }

    // MARK: - API

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        var components = URLComponents(string: "https://www.googleapis.com/calendar/v3" + path)!
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(try await validAccessToken())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw GoogleError.http(status, String(data: data, encoding: .utf8) ?? "") }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private struct CalendarListResponse: Decodable {
        struct Entry: Decodable {
            let id: String
            let summary: String
            let summaryOverride: String?
            let backgroundColor: String?
            let primary: Bool?
            let accessRole: String?
        }
        let items: [Entry]
    }

    func loadCalendars() async throws {
        let response: CalendarListResponse = try await get("/users/me/calendarList")
        calendars = response.items.map {
            CalendarInfo(id: $0.id,
                         name: $0.summaryOverride ?? $0.summary,
                         color: $0.backgroundColor.flatMap(Color.init(hex:)) ?? .blue,
                         isPrimary: $0.primary ?? false,
                         accessRole: $0.accessRole ?? "reader")
        }
        .sorted { ($0.isPrimary ? 0 : 1, $0.name) < ($1.isPrimary ? 0 : 1, $1.name) }
    }

    enum MoveError: LocalizedError {
        case needsPermission, notAllowed(String)

        var errorDescription: String? {
            switch self {
            case .needsPermission:
                "Reconnect Google in Settings → Calendar to allow rescheduling."
            case .notAllowed(let detail):
                "Google wouldn't move this event (you may not be its organizer). \(detail)"
            }
        }
    }

    /// Moves an event. Timed events get explicit local start/end times; all-day events use dates (end exclusive).
    /// Guests, if any, are emailed about the change, as Google Calendar does.
    func move(calendarID: String, eventID: String, start: Date, end: Date, allDay: Bool) async throws {
        guard canEditEvents else { throw MoveError.needsPermission }
        let path = "/calendars/\(Self.pathComponent(calendarID))/events/\(Self.pathComponent(eventID))"
        var components = URLComponents(string: "https://www.googleapis.com/calendar/v3" + path)!
        components.queryItems = [.init(name: "sendUpdates", value: "all")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(try await validAccessToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.moveBody(start: start, end: end, allDay: allDay))
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            if status == 403, body.contains("insufficient") { throw MoveError.needsPermission }
            if status == 403 { throw MoveError.notAllowed("") }
            throw GoogleError.http(status, body)
        }
    }

    /// The calendar new events go to: the primary one if editable, else the first editable one.
    var defaultCalendarForNewEvents: CalendarInfo? {
        calendars.first { $0.isPrimary && $0.canEdit } ?? calendars.first(where: \.canEdit)
    }

    /// Creates an event (no guests, so nobody is emailed).
    func insert(summary: String, calendarID: String, start: Date, end: Date, allDay: Bool) async throws {
        guard canEditEvents else { throw MoveError.needsPermission }
        let path = "/calendars/\(Self.pathComponent(calendarID))/events"
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/calendar/v3" + path)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(try await validAccessToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body = Self.moveBody(start: start, end: end, allDay: allDay)
        body["summary"] = summary
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 || status == 201 else {
            let text = String(data: data, encoding: .utf8) ?? ""
            if status == 403, text.contains("insufficient") { throw MoveError.needsPermission }
            throw GoogleError.http(status, text)
        }
    }

    static func moveBody(start: Date, end: Date, allDay: Bool) -> [String: Any] {
        if allDay {
            return ["start": ["date": DateParsing.dayString(start)], "end": ["date": DateParsing.dayString(end)]]
        }
        let zone = TimeZone.current.identifier
        return ["start": ["dateTime": DateParsing.localRFC3339(start), "timeZone": zone],
                "end": ["dateTime": DateParsing.localRFC3339(end), "timeZone": zone]]
    }

    private static func pathComponent(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? s
    }

    private struct EventsResponse: Decodable {
        struct Event: Decodable {
            struct When: Decodable { let date: String?; let dateTime: String? }
            let id: String
            let status: String?
            let summary: String?
            let start: When?
            let end: When?
            let htmlLink: String?
            let hangoutLink: String?
            let location: String?
            let conferenceData: ConferenceData?
        }

        /// Meet, and add-ons like Zoom/Teams/Webex, put their join links here.
        struct ConferenceData: Decodable {
            struct EntryPoint: Decodable { let entryPointType: String?; let uri: String? }
            let entryPoints: [EntryPoint]?

            var videoLink: String? {
                entryPoints?.first { $0.entryPointType == "video" }?.uri
            }
        }
        let items: [Event]
    }

    func items(from start: Date, to end: Date) async throws -> [CalendarItem] {
        guard isSignedIn else { return [] }
        if calendars.isEmpty { try await loadCalendars() }

        var result: [CalendarItem] = []
        for calendar in calendars where !hiddenCalendarIDs.contains(calendar.id) {
            let id = calendar.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? calendar.id
            let response: EventsResponse = try await get("/calendars/\(id)/events", query: [
                .init(name: "timeMin", value: DateParsing.rfc3339(start)),
                .init(name: "timeMax", value: DateParsing.rfc3339(end)),
                .init(name: "singleEvents", value: "true"),
                .init(name: "orderBy", value: "startTime"),
                .init(name: "maxResults", value: "100"),
            ])
            for event in response.items where event.status != "cancelled" {
                guard let startString = event.start?.dateTime ?? event.start?.date,
                      let (startDate, allDay) = DateParsing.parse(startString) else { continue }
                let endDate = (event.end?.dateTime ?? event.end?.date).flatMap { DateParsing.parse($0)?.0 }
                result.append(CalendarItem(
                    id: "google:\(calendar.id):\(event.id)",
                    title: event.summary ?? "(No title)",
                    start: startDate,
                    end: endDate,
                    isAllDay: allDay,
                    color: calendar.color,
                    calendarName: calendar.name,
                    calendarID: calendar.id,
                    eventID: event.id,
                    canEdit: calendar.canEdit,
                    url: event.htmlLink.flatMap(URL.init(string:)),
                    meetingURL: MeetingLinks.link(conferenceVideo: event.conferenceData?.videoLink,
                                                  hangoutLink: event.hangoutLink, location: event.location),
                    location: event.location
                ))
            }
        }
        return result
    }
}
