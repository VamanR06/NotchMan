import Foundation
import NotchKit

/// Reads applications from a JobManager server (github.com/VamanR06/JobManager).
///
/// Signs in like the web app: POST the password to /api/auth/login and keep the `jm_session`
/// cookie (valid 30 days). The password is kept in the Keychain so an expired session renews itself.
@MainActor
final class JobManagerClient {
    enum ClientError: LocalizedError {
        case notSignedIn, wrongPassword, lockedOut, insecureURL, http(Int)

        var errorDescription: String? {
            switch self {
            case .notSignedIn: "Not signed in to JobManager."
            case .wrongPassword: "Wrong JobManager password."
            case .lockedOut: "Too many wrong passwords. JobManager locks sign-in for 15 minutes."
            case .insecureURL: "Use an https:// URL (plain http is only allowed for localhost)."
            case .http(let code): "JobManager returned HTTP \(code)."
            }
        }
    }

    static let defaultServer = "https://jobs.vamanr.com"
    private static let cookieName = "jm_session"

    private let keychain: Keychain
    private let defaults: UserDefaults
    /// Ephemeral, no automatic cookies or redirects: the login response's cookie and Location are read by hand.
    private let session = URLSession(configuration: {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 20
        return config
    }(), delegate: NoRedirects(), delegateQueue: nil)

    init(keychain: Keychain, defaults: UserDefaults) {
        self.keychain = keychain
        self.defaults = defaults
    }

    var serverURL: String {
        defaults.string(forKey: "serverURL") ?? Self.defaultServer
    }

    var isSignedIn: Bool {
        keychain.string(for: "password") != nil || keychain.string(for: "session") != nil
    }

    static func validate(_ string: String) throws -> URL {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed), let host = url.host() else { throw ClientError.insecureURL }
        let local = ["localhost", "127.0.0.1", "::1"].contains(host)
        guard url.scheme == "https" || (url.scheme == "http" && local) else { throw ClientError.insecureURL }
        return url
    }

    /// Signs in and remembers the server, password and session.
    func signIn(server: String, password: String) async throws {
        let base = try Self.validate(server)
        let cookie = try await login(base: base, password: password)
        defaults.set(base.absoluteString, forKey: "serverURL")
        keychain.set(password, for: "password")
        keychain.set(cookie, for: "session")
    }

    func signOut() {
        keychain.remove("password")
        keychain.remove("session")
    }

    /// Returns the session cookie value, or "" for a server with no password set.
    private func login(base: URL, password: String) async throws -> String {
        var request = URLRequest(url: base.appending(path: "api/auth/login"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [.init(name: "password", value: password), .init(name: "next", value: "/")]
        request.httpBody = Data((form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.http(0) }
        return try Self.sessionCookie(from: http, base: base)
    }

    /// Interprets the login response: a redirect back to /login carries the error;
    /// otherwise the session cookie is in Set-Cookie.
    static func sessionCookie(from response: HTTPURLResponse, base: URL) throws -> String {
        guard (300..<400).contains(response.statusCode) else { throw ClientError.http(response.statusCode) }
        let location = response.value(forHTTPHeaderField: "Location") ?? ""
        if location.hasPrefix("/login") {
            throw location.contains("error=locked") ? ClientError.lockedOut : ClientError.wrongPassword
        }
        var headers: [String: String] = [:]
        for case let (key as String, value as String) in response.allHeaderFields { headers[key] = value }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: base)
        return cookies.first { $0.name == cookieName }?.value ?? ""
    }

    func jobs() async throws -> [TrackedJob] {
        let data = try await authorizedGet("api/jobs")
        return try JSONDecoder().decode([JobRecord].self, from: data).map(TrackedJob.init)
    }

    /// The saved posting snapshot for a job, or nil if none was saved.
    func posting(for job: TrackedJob) async throws -> JobPosting? {
        let data = try await authorizedGet("api/jobs/\(job.id)/posting")
        return try JSONDecoder().decode(JobPosting?.self, from: data)
    }

    /// Logs `status` for `job` (JobManager keeps status as a log of events) and returns the new event's id, so
    /// it can be undone. Moving an interview to another interview starts the next round.
    func setStatus(_ status: JobStatus, for job: TrackedJob) async throws -> Int {
        let body = Self.statusEventBody(status, for: job)
        let data = try await authorized("POST", "api/events", json: body, accept: [200, 201])
        struct Created: Decodable { let id: Int }
        return try JSONDecoder().decode(Created.self, from: data).id
    }

    static func statusEventBody(_ status: JobStatus, for job: TrackedJob) -> [String: Any] {
        var body: [String: Any] = ["job_id": job.id, "status": status.rawValue]
        if status == .interview {
            body["interview_round"] = job.status == .interview ? (job.round ?? 1) + 1 : 1
        }
        return body
    }

    /// Removes a status event (undo).
    func deleteEvent(_ id: Int) async throws {
        _ = try await authorized("DELETE", "api/events/\(id)", json: nil, accept: [200, 204])
    }

    /// GET with the session cookie, signing in again once if the session expired.
    private func authorizedGet(_ path: String) async throws -> Data {
        try await authorized("GET", path, json: nil, accept: [200])
    }

    /// A request with the session cookie, signing in again once if the session expired. No `Origin` header is
    /// sent: JobManager refuses cross-site writes, and a native request without one passes its check.
    private func authorized(_ method: String, _ path: String, json: [String: Any]?, accept: Set<Int>) async throws -> Data {
        let base = try Self.validate(serverURL)
        guard isSignedIn else { throw ClientError.notSignedIn }

        var (data, status) = try await send(method, path, json: json, base: base)
        if status == 401, let password = keychain.string(for: "password") {
            // Session expired or the password changed on the server: sign in again once.
            let cookie = try await login(base: base, password: password)
            keychain.set(cookie, for: "session")
            (data, status) = try await send(method, path, json: json, base: base)
        }
        if status == 401 { throw ClientError.notSignedIn }
        guard accept.contains(status) else { throw ClientError.http(status) }
        return data
    }

    private func send(_ method: String, _ path: String, json: [String: Any]?, base: URL) async throws -> (Data, Int) {
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = method
        if let cookie = keychain.string(for: "session"), !cookie.isEmpty {
            request.setValue("\(Self.cookieName)=\(cookie)", forHTTPHeaderField: "Cookie")
        }
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    func pageURL(for job: TrackedJob) -> URL? {
        URL(string: serverURL)?.appending(path: "jobs/\(job.id)")
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
