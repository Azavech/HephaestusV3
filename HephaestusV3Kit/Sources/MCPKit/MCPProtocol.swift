import Foundation

/// The answer to one HTTP body of `/mcp` (docs/mcp.md › JSON-RPC).
public enum MCPReply: Sendable, Hashable {
    /// 200 with a JSON-RPC response.
    case json(JSONValue)
    /// 202 without a body: a notification, or a response from the client.
    case accepted
    /// 400: the `MCP-Protocol-Version` header names a version the server doesn't speak.
    case unsupportedVersion(String)
}

/// JSON-RPC over MCP: the classification of a message, `initialize`, `ping`, `tools/list` and `tools/call`.
/// Stateless: each body is handled on its own.
public struct MCPProtocol: Sendable {
    public static let supportedVersions = ["2025-06-18", "2025-03-26"]
    public static let serverName = "hephaestus"

    /// Decides, before a call runs, whether its caller may make it: nil lets it run; an error refuses it. A
    /// chat's change may wait there for the user's answer (docs/mcp.md › Permissions).
    public typealias Gate = @Sendable (MCPCaller, ToolOperation, JSONValue) async -> ToolError?

    public let registry: ToolRegistry
    /// The app's version, in `serverInfo`.
    public let version: String
    public let gate: Gate?

    public init(registry: ToolRegistry, version: String, gate: Gate? = nil) {
        self.registry = registry
        self.version = version
        self.gate = gate
    }

    /// Handles a body; `protocolVersions` are the values of its `MCP-Protocol-Version` header fields, `caller` who
    /// sent it.
    public func handle(body: Data, protocolVersions: [String] = [], caller: MCPCaller = .external) async -> MCPReply {
        guard let message = try? JSONValue.parse(body) else { return .json(Self.error(nil, -32700, "Parse error")) }
        if case .array = message { return invalid("batches are not supported") }
        guard case .object(let object) = message else { return invalid("the message must be a JSON object") }
        guard object["jsonrpc"] == .string("2.0") else { return invalid("jsonrpc must be \"2.0\"") }
        if let method = object["method"] {
            guard case .string(let name) = method else { return invalid("method must be a string") }
            guard let id = object["id"] else { return .accepted }
            switch id {
            case .string, .int: break
            default: return invalid("id must be a string or an integer")
            }
            return await MCPCaller.$current.withValue(caller) {
                await request(name, id: id, params: object["params"], protocolVersions: protocolVersions)
            }
        }
        if object["result"] != nil || object["error"] != nil { return .accepted }
        return invalid("method must be a string")
    }

    private func request(_ method: String, id: JSONValue, params: JSONValue?, protocolVersions: [String]) async -> MCPReply {
        guard ["initialize", "ping", "tools/list", "tools/call"].contains(method) else {
            return .json(Self.error(id, -32601, "Method not found: \(method)"))
        }
        if method != "initialize", let unsupported = protocolVersions.first(where: { !Self.supportedVersions.contains($0) }) {
            return .unsupportedVersion(unsupported)
        }
        if let params, params.objectValue == nil {
            return .json(Self.error(id, -32602, "Invalid params: params must be an object"))
        }
        switch method {
        case "initialize":
            guard let requested = params?["protocolVersion"]?.stringValue else {
                return .json(Self.error(id, -32602, "Invalid params: protocolVersion must be a string"))
            }
            let version = Self.supportedVersions.contains(requested) ? requested : Self.supportedVersions[0]
            return .json(Self.result(id, [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": .string(Self.serverName), "version": .string(self.version)],
            ]))
        case "ping":
            return .json(Self.result(id, [:]))
        case "tools/list":
            return .json(Self.result(id, ["tools": .array(registry.operations.map(\.listing))]))
        default:
            guard let name = params?["name"]?.stringValue else {
                return .json(Self.error(id, -32602, "Invalid params: name must be a string"))
            }
            let arguments = params?["arguments"] ?? .null
            guard arguments == .null || arguments.objectValue != nil else {
                return .json(Self.error(id, -32602, "Invalid params: arguments must be an object"))
            }
            guard let operation = registry[name] else { return .json(Self.error(id, -32602, "Unknown tool: \(name)")) }
            return .json(Self.result(id, await call(operation, arguments: arguments == .null ? [:] : arguments)))
        }
    }

    /// A tool call's result: one text item, the result's JSON, or the error's message with `isError`.
    func call(_ operation: ToolOperation, arguments: JSONValue) async -> JSONValue {
        if let violation = operation.inputSchema.violation(of: arguments) {
            return Self.toolResult(violation, isError: true)
        }
        let arguments = arguments.removingNullMembers
        if let refusal = await gate?(MCPCaller.current, operation, arguments) {
            return Self.toolResult(refusal.message, isError: true)
        }
        do throws(ToolError) {
            let value = try await operation.run(arguments)
            return Self.toolResult(value.text, isError: false)
        } catch {
            return Self.toolResult(error.message, isError: true)
        }
    }

    static func toolResult(_ text: String, isError: Bool) -> JSONValue {
        ["content": [["type": "text", "text": .string(text)]], "isError": .bool(isError)]
    }

    private func invalid(_ reason: String) -> MCPReply {
        .json(Self.error(nil, -32600, "Invalid Request: \(reason)"))
    }

    static func result(_ id: JSONValue, _ result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func error(_ id: JSONValue?, _ code: Int, _ message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id ?? .null, "error": ["code": .int(code), "message": .string(message)]]
    }
}
