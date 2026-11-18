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

/// What a tool may do, and which of the user's permissions covers it in a chat (docs/mcp.md › Permissions).
public enum ToolPermission: String, Sendable, Hashable, CaseIterable {
    /// Reads, or opens a window: always allowed.
    case read
    /// Creates or changes tickets, bundles and comments: Settings ▸ Chat › Change tickets.
    case changeTickets
    /// Deletes tickets, bundles, comments or attachments: asks first, unless Change tickets is Never.
    case deleteTickets
    /// Adds a project or changes its settings: Settings ▸ Chat › Change projects.
    case changeProjects
    /// Removes a project from the app: asks first, unless Change projects is Never.
    case removeProjects
    /// Renames a chat: always allowed.
    case renameChats
    /// Asks the user in the calling chat (`ask_questions`): always allowed, to a chat's own Claude only.
    case askUser
    /// Closes chats (`close_chat`): a chat's own runs; another chat asks first.
    case closeChats
    /// Re-runs or cancels a workflow run: Settings ▸ Chat › Start builds.
    case startBuilds
    /// Calls an API of a project's contract: a `GET` or `HEAD` always runs; another method follows Settings ▸
    /// Chat › Call APIs that change data.
    case callAPIs
    /// Restarts, scales or syncs a Deployment, or forwards a port: Settings ▸ Chat › Operate deployments.
    case operateClusters
    /// Creates, starts or stops a virtual machine, or acts in one (shell, input, files): Settings ▸ Chat ›
    /// Operate virtual machines.
    case operateMachines

    /// True for the permissions that change the user's data.
    public var changes: Bool { self != .read }
}

/// How a chat shows a call of an operation, in its tool's words (docs/ui/chat.md › Tool-call rows).
public struct ToolCallText: Sendable, Hashable {
    /// What the call does: `Read ticket ORD-142`, `Listed the tickets of ORD`.
    public var action: String
    /// For a change, the approval card's title: `Claude wants to comment on ORD-142`.
    public var request: String?
    /// For a change, what it would write: a comment's text, a new title.
    public var preview: String?
    /// The item it reads or changes, which the chat opens in its tool.
    public var item: ToolItem?

    public init(action: String, request: String? = nil, preview: String? = nil, item: ToolItem? = nil) {
        self.action = action
        self.request = request
        self.preview = preview
        self.item = item
    }
}

/// An item of a tool, as a route opens it: `tickets`, `ORD`, `ORD-142`, `ORD-142`.
public struct ToolItem: Sendable, Hashable {
    /// The tool, a `ToolKind` value; `projects` for a project.
    public var tool: String
    public var projectID: String
    /// The tool's id for the item, empty for the tool's window without a selection.
    public var focus: String
    public var title: String

    public init(tool: String, projectID: String, focus: String, title: String) {
        self.tool = tool
        self.projectID = projectID
        self.focus = focus
        self.title = title
    }
}

/// One operation of a tool, which the MCP server offers to Claude: its name, description and input schema,
/// and the function it runs, the same one the tool's window calls. Each kit declares its own; ToolsScenes
/// gathers them in a `ToolRegistry`.
public struct ToolOperation: Sendable {
    public let name: String
    public let description: String
    public let inputSchema: ToolSchema
    public let permission: ToolPermission
    /// How a chat shows a call with these arguments; nil shows the tool's name.
    public let describe: (@Sendable (JSONValue) -> ToolCallText)?
    /// Runs the call with its arguments, already validated against `inputSchema`, `null` members removed;
    /// returns the result as JSON.
    public let run: @Sendable (JSONValue) async throws(ToolError) -> JSONValue

    public init(name: String, description: String, inputSchema: ToolSchema, permission: ToolPermission,
                describe: (@Sendable (JSONValue) -> ToolCallText)? = nil,
                run: @escaping @Sendable (JSONValue) async throws(ToolError) -> JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.permission = permission
        self.describe = describe
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
