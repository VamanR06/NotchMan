import CryptoKit
import Foundation

/// Proof Key for Code Exchange (RFC 7636) for OAuth sign-in from a desktop app.
public struct PKCE: Sendable {
    public let verifier: String
    /// base64url(SHA256(verifier)), sent with `code_challenge_method=S256`.
    public let challenge: String

    public init() {
        self.init(verifier: Self.randomString(length: 64))
    }

    init(verifier: String) {
        self.verifier = verifier
        challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Cryptographically random URL-safe string (also used for the OAuth `state`).
    public static func randomString(length: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<length).map { _ in chars.randomElement()! })
    }
}
