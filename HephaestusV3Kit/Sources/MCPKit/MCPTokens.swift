import Foundation
import Security
import Synchronization

/// Who calls a tool: Claude with the external token (a terminal session), or Claude in one of the app's
/// chats, with that chat's token (docs/mcp.md › Authentication).
public enum MCPCaller: Sendable, Hashable {
    case external
    case chat(String)

    /// The chat's id; nil for the external token.
    public var chatID: String? {
        if case .chat(let id) = self { id } else { nil }
    }

    /// The caller of the tool call running, which the tools read to record who made a change.
    @TaskLocal public static var current: MCPCaller = .external
}

/// The bearer tokens the server accepts (docs/mcp.md › Authentication): 64 lowercase hexadecimal characters
/// encoding 32 random bytes, compared in constant time, never logged. The external tokens stay until replaced;
/// a chat's token lives as long as the chat's process.
public final class MCPTokens: Sendable {
    private let tokens = Mutex<[String: MCPCaller]>([:])

    public init(_ tokens: Set<String> = []) {
        self.tokens.withLock { $0 = Dictionary(uniqueKeysWithValues: tokens.map { ($0, .external) }) }
    }

    /// Replaces the external tokens; a token left out stops working at once. The chats' tokens stay.
    public func replace(with tokens: Set<String>) {
        self.tokens.withLock { current in
            current = current.filter { $0.value != .external }
            for token in tokens { current[token] = .external }
        }
    }

    /// A new token for a chat's process.
    public func issue(forChat chatID: String) -> String {
        let token = Self.generate()
        tokens.withLock { $0[token] = .chat(chatID) }
        return token
    }

    /// Ends a chat's token.
    public func revoke(_ token: String) {
        _ = tokens.withLock { $0.removeValue(forKey: token) }
    }

    /// True when `token` is accepted.
    public func accepts(_ token: String) -> Bool {
        caller(for: token) != nil
    }

    /// Who presents `token`; nil when it isn't accepted. Every token is compared, each in constant time.
    public func caller(for token: String) -> MCPCaller? {
        let presented = Array(token.utf8)
        var found: MCPCaller?
        for (candidate, caller) in tokens.withLock({ $0 }) where Self.equal(Array(candidate.utf8), presented) {
            found = caller
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
