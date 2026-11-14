import Foundation

/// Why a tool call failed, as Claude reads it: the message alone, the code for the logs
/// (docs/mcp.md › Tool errors).
public struct ToolError: Error, Sendable, Hashable {
    public enum Code: String, Sendable, Hashable {
        case notFound, invalid, conflict, forbidden, unavailable, `internal`
    }

    public var code: Code
    /// `<argument>: <reason>.` for an invalid argument, else a sentence.
    public var message: String

    public init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }
}

/// What a tool may do: read, or change the user's data. The chat's approvals use it.
public enum ToolPermission: String, Sendable, Hashable {
    case read
    case change
}

/// One operation of a tool, which the MCP server offers to Claude: its name, description and input schema,
/// and the function it runs, the same one the tool's window calls. Each kit declares its own; ToolsScenes
/// gathers them in a `ToolRegistry`.
public struct ToolOperation: Sendable {
    public let name: String
    public let description: String
    public let inputSchema: ToolSchema
    public let permission: ToolPermission
    /// Runs the call with its arguments, already validated against `inputSchema`, `null` members removed;
    /// returns the result as JSON.
    public let run: @Sendable (JSONValue) async throws(ToolError) -> JSONValue

    public init(name: String, description: String, inputSchema: ToolSchema, permission: ToolPermission,
                run: @escaping @Sendable (JSONValue) async throws(ToolError) -> JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.permission = permission
        self.run = run
    }

    /// The element of `tools/list`: `name`, `description`, `inputSchema`.
    public var listing: JSONValue {
        ["name": .string(name), "description": .string(description), "inputSchema": inputSchema.json]
    }
}

/// The tools the MCP server offers, in the order `tools/list` gives them.
public struct ToolRegistry: Sendable {
    public let operations: [ToolOperation]

    public init(_ operations: [ToolOperation]) {
        precondition(Set(operations.map(\.name)).count == operations.count, "Two tools have the same name.")
        self.operations = operations
    }

    public var names: [String] { operations.map(\.name) }

    public subscript(name: String) -> ToolOperation? {
        operations.first { $0.name == name }
    }
}

extension JSONValue {
    /// A required string argument; throws the argument's `required` error otherwise.
    public func string(_ name: String) throws(ToolError) -> String {
        guard let value = self[name]?.stringValue else { throw ToolError(.invalid, "\(name): required.") }
        return value
    }
}
