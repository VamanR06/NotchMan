import Foundation
import Network

/// A small long-running HTTP server on 127.0.0.1 that tools on this Mac call into: Claude Code's
/// PermissionRequest hook (Agents app) and `notchman-run` progress pings (Shelf app).
///
/// Every request must carry `Authorization: Bearer <token>`, a random secret kept in
/// `~/Library/Application Support/NotchMan/hook-token` (readable only by you), so other local processes and web
/// pages can't drive it. Handlers may take their time (waiting for you to click Allow); if the caller hangs up
/// first, the handler's task is cancelled.
public final class HookServer: @unchecked Sendable {
    public static let port: UInt16 = 43822
    public static let shared = HookServer()

    public struct Request: Sendable {
        public let method: String
        public let path: String
        /// Header names lowercased.
        public let headers: [String: String]
        public let body: Data
    }

    public struct Response: Sendable {
        public var status: Int
        public var body: Data

        public init(status: Int = 200, body: Data = Data()) {
            self.status = status
            self.body = body
        }

        public static let empty = Response()
        public static func json(_ object: Any) -> Response {
            Response(body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
        }
    }

    public typealias Handler = @Sendable (Request) async -> Response

    private let queue = DispatchQueue(label: "com.notchman.hooks")
    private var listener: NWListener?
    private var routes: [String: Handler] = [:]
    private let maxRequest = 1 << 20

    /// The shared secret callers must send.
    public let token: String

    /// The port this instance listens on (`HookServer.port` for the shared one).
    let listenPort: UInt16

    /// `port` other than the default is for tests, which mustn't collide with a running NotchMan.
    init(port: UInt16 = HookServer.port) {
        listenPort = port
        token = Self.loadOrCreateToken()
    }

    /// Serves `path` with `handler`, starting the server on first use.
    public func route(_ path: String, handler: @escaping Handler) {
        queue.async { [self] in
            routes[path] = handler
            startIfNeeded()
        }
    }

    private func startIfNeeded() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: listenPort)!)
        params.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: params) else { return }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                // Port in use (another copy running): try again later.
                self?.queue.asyncAfter(deadline: .now() + 10) {
                    self?.listener = nil
                    self?.startIfNeeded()
                }
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                respond(to: request, on: connection)
            } else if isComplete || error != nil || buffer.count > maxRequest {
                connection.cancel()
            } else {
                receive(on: connection, buffer: buffer)
            }
        }
    }

    private func respond(to request: Request, on connection: NWConnection) {
        guard request.headers["authorization"] == "Bearer \(token)" else {
            send(Response(status: 401), on: connection)
            return
        }
        guard request.method == "POST", let handler = routes[request.path] else {
            send(Response(status: 404), on: connection)
            return
        }
        let task = Task {
            let response = await handler(request)
            queue.async { [self] in send(response, on: connection) }
        }
        // The caller hanging up (Claude Code interrupted, hook timed out) cancels the handler.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, isComplete, error in
            if isComplete || error != nil { task.cancel() }
        }
    }

    private func send(_ response: Response, on connection: NWConnection) {
        let reason = [200: "OK", 401: "Unauthorized", 404: "Not Found"][response.status] ?? "Status"
        var head = "HTTP/1.1 \(response.status) \(reason)\r\nContent-Length: \(response.body.count)\r\n"
        if !response.body.isEmpty { head += "Content-Type: application/json\r\n" }
        head += "Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + response.body, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// A complete request (headers plus Content-Length body), or nil if more bytes are needed.
    static func parse(_ data: Data) -> Request? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[headerEnd.upperBound...]
        guard body.count >= length else { return nil }
        let path = String(requestLine[1]).components(separatedBy: "?")[0]
        return Request(method: String(requestLine[0]), path: path, headers: headers, body: Data(body.prefix(length)))
    }

    // MARK: - Token

    public static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "NotchMan")
    }

    private static func loadOrCreateToken() -> String {
        let file = supportDirectory.appending(path: "hook-token")
        if let existing = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           existing.count >= 32 {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600])
        return token
    }
}
