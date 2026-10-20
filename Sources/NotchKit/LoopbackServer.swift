import Foundation
import Network

/// One-shot HTTP server on 127.0.0.1 that receives an OAuth redirect.
/// All mutable state is confined to `queue`.
public final class LoopbackServer: @unchecked Sendable {
    public enum ServerError: Error { case noPort, cancelled }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.notchman.oauth-loopback")
    private var startContinuation: CheckedContinuation<UInt16, Error>?
    private var callbackContinuation: CheckedContinuation<URL, Error>?
    private var earlyResult: Result<URL, Error>?

    /// Listens on `port`, or any free port when nil (for providers that accept dynamic loopback ports).
    public init(port: UInt16? = nil) throws {
        let params = NWParameters.tcp
        let fixed = port.flatMap(NWEndpoint.Port.init(rawValue:))
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: fixed ?? .any)
        listener = try NWListener(using: params)
    }

    /// Starts listening and returns the bound port.
    public func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                startContinuation = continuation
                listener.stateUpdateHandler = { [self] state in
                    switch state {
                    case .ready:
                        if let port = listener.port?.rawValue {
                            startContinuation?.resume(returning: port)
                        } else {
                            startContinuation?.resume(throwing: ServerError.noPort)
                        }
                        startContinuation = nil
                    case .failed(let error):
                        startContinuation?.resume(throwing: error)
                        startContinuation = nil
                        finish(.failure(error))
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [self] connection in handle(connection) }
                listener.start(queue: queue)
            }
        }
    }

    /// Waits for the browser to hit the redirect URL; returns the full callback URL.
    public func waitForCallback() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                if let earlyResult {
                    continuation.resume(with: earlyResult)
                } else {
                    callbackContinuation = continuation
                }
            }
        }
    }

    public func cancel() {
        queue.async { [self] in finish(.failure(ServerError.cancelled)) }
    }

    private func finish(_ result: Result<URL, Error>) {
        if let callbackContinuation {
            callbackContinuation.resume(with: result)
            self.callbackContinuation = nil
        } else if earlyResult == nil {
            earlyResult = result
        }
        listener.cancel()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [self] data, _, _, _ in
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            // Request line: "GET /?code=...&state=... HTTP/1.1"
            let parts = request.split(separator: "\n").first?.split(separator: " ") ?? []
            let path = parts.count > 1 ? String(parts[1]) : "/"
            guard let url = URL(string: "http://127.0.0.1\(path)"),
                  let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                  items.contains(where: { $0.name == "code" || $0.name == "error" }) else {
                respond(connection, status: "404 Not Found", body: "")
                return
            }
            let body = """
            <html><body style="font-family:-apple-system;text-align:center;padding-top:80px">
            <h2>NotchMan is connected.</h2><p>You can close this tab.</p></body></html>
            """
            respond(connection, status: "200 OK", body: body)
            finish(.success(url))
        }
    }

    private func respond(_ connection: NWConnection, status: String, body: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}
