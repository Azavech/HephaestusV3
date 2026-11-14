import Foundation
import Security
import Synchronization

/// The bearer tokens the server accepts (docs/mcp.md › Authentication): 64 lowercase hexadecimal characters
/// encoding 32 random bytes, compared in constant time, never logged.
public final class MCPTokens: Sendable {
    private let tokens = Mutex<Set<String>>([])

    public init(_ tokens: Set<String> = []) {
        self.tokens.withLock { $0 = tokens }
    }

    /// Replaces the accepted tokens; a token left out stops working at once.
    public func replace(with tokens: Set<String>) {
        self.tokens.withLock { $0 = tokens }
    }

    /// True when `token` is accepted. Every accepted token is compared, each in constant time.
    public func accepts(_ token: String) -> Bool {
        let presented = Array(token.utf8)
        var found = false
        for candidate in tokens.withLock({ $0 }) where Self.equal(Array(candidate.utf8), presented) {
            found = true
        }
        return found
    }

    /// A new token from `SecRandomCopyBytes`.
    public static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// The token of an `Authorization` field: `Bearer <token>`, the scheme in any case; nil otherwise.
    static func bearer(_ fields: [String]) -> String? {
        guard fields.count == 1 else { return nil }
        let parts = fields[0].split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        let token = parts[1].trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }

    private static func equal(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices { difference |= lhs[index] ^ rhs[index] }
        return difference == 0
    }
}
