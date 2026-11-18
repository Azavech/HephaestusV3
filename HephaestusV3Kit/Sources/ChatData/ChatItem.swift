import FileStorage
import Foundation
import MCPKit

/// One item of a chat's transcript (docs/data.md › Chat items): the items the app reads and writes. Other
/// items (question pickers and shown images) are skipped when a transcript is read.
public enum ChatItem: Sendable, Hashable, Identifiable {
    case user(UserItem)
    case assistant(AssistantItem)
    case thinking(ThinkingItem)
    case toolUse(ToolUseItem)
    case toolResult(ToolResultItem)
    case permissionRequest(PermissionRequestItem)
    case system(SystemItem)
    case result(ResultItem)

    public var id: String {
        switch self {
        case .user(let item): item.id
        case .assistant(let item): item.id
        case .thinking(let item): item.id
        case .toolUse(let item): item.id
        case .toolResult(let item): item.id
        case .permissionRequest(let item): item.id
        case .system(let item): item.id
        case .result(let item): item.id
        }
    }

    public var created: Date {
        switch self {
        case .user(let item): item.created
        case .assistant(let item): item.created
        case .thinking(let item): item.created
        case .toolUse(let item): item.created
        case .toolResult(let item): item.created
        case .permissionRequest(let item): item.created
        case .system(let item): item.created
        case .result(let item): item.created
        }
    }
}

/// A message sent to Claude.
public struct UserItem: Sendable, Hashable {
    public var id: String
    public var created: Date
    /// The message as the user wrote it, without the lines V3 adds for Claude (docs/ui/chat.md › What Claude
    /// receives).
    public var text: String
    /// The files sent with the message, stored in the chat's folder: a feedback chat's screenshot and files.
    public var attachments: [MessageAttachment]
    /// The Mac whose user sent it.
    public var sender: String
    /// Linked items, kept as read.
    public var linkedItems: JSONValue
    /// V3 addition: the items the message carried, each a tool's item or the project.
    public var references: [ChatItemReference]

    public init(id: String = UUID().uuidString, created: Date, text: String, sender: String, references: [ChatItemReference] = [],
                attachments: [MessageAttachment] = []) {
        self.id = id
        self.created = created
        self.text = text
        self.attachments = attachments
        self.sender = sender
        linkedItems = []
        self.references = references
    }
}

/// V3 addition: an item a message carried, as the chip showed it (docs/data.md › Chat items).
public struct ChatItemReference: Sendable, Hashable {
    /// The tool, a `ToolKind` value such as `tickets`; `project` for the project itself.
    public var tool: String
    public var projectID: String
    /// The tool's id for the item, such as `ORD-142`; empty for the project.
    public var focus: String
    public var title: String
    /// The environment the item was seen in, for the Service Map.
    public var environment: String?

    public init(tool: String, projectID: String, focus: String, title: String, environment: String? = nil) {
        self.tool = tool
        self.projectID = projectID
        self.focus = focus
        self.title = title
        self.environment = environment
    }

    /// The `tool` of the project itself.
    public static let projectTool = "project"
    /// The `tool` of a file on this Mac, such as the feedback's screenshot: `focus` is its absolute path,
    /// `title` its name.
    public static let fileTool = "file"
}

/// A text block Claude wrote.
public struct AssistantItem: Sendable, Hashable {
    public var id: String
    public var created: Date
    public var text: String
    public var messageID: String
    /// The sub-agent call whose work this is; nil in the main conversation.
    public var parentToolUseID: String?
    /// The CLI's id of the model that wrote it, such as `claude-opus-5-5`.
    public var model: String?
    public var effort: Effort?

    public init(id: String, created: Date, text: String, messageID: String, parentToolUseID: String? = nil, model: String? = nil,
                effort: Effort? = nil) {
        self.id = id
        self.created = created
        self.text = text
        self.messageID = messageID
        self.parentToolUseID = parentToolUseID
        self.model = model
        self.effort = effort
    }
}

/// A thinking block, which V3 keeps and doesn't show.
public struct ThinkingItem: Sendable, Hashable {
    public var id: String
    public var created: Date
    public var text: String
    public var parentToolUseID: String?

    public init(id: String, created: Date, text: String, parentToolUseID: String? = nil) {
        self.id = id
        self.created = created
        self.text = text
        self.parentToolUseID = parentToolUseID
    }
}

/// A tool call.
public struct ToolUseItem: Sendable, Hashable {
    public var id: String
    public var created: Date
    public var toolUseID: String
    /// The tool's own name: `get_ticket` for `mcp__hephaestus__get_ticket`.
    public var name: String
    /// The MCP server, such as `hephaestus`; nil for a tool of the CLI.
    public var server: String?
    public var input: JSONValue
    public var parentToolUseID: String?

    public init(id: String, created: Date, toolUseID: String, name: String, server: String?, input: JSONValue,
                parentToolUseID: String? = nil) {
        self.id = id
        self.created = created
        self.toolUseID = toolUseID
        self.name = name
        self.server = server
        self.input = input
        self.parentToolUseID = parentToolUseID
    }

    /// `mcp__<server>__<tool>` split after `mcp__` at the next `__`; another name has no server.
    public static func split(_ cliName: String) -> (name: String, server: String?) {
        guard cliName.hasPrefix("mcp__") else { return (cliName, nil) }
        let rest = cliName.dropFirst("mcp__".count)
        guard let separator = rest.range(of: "__") else { return (cliName, nil) }
        return (String(rest[separator.upperBound...]), String(rest[..<separator.lowerBound]))
    }
}

/// The result of a tool call.
public struct ToolResultItem: Sendable, Hashable {
    public var id: String
    public var created: Date
    public var toolUseID: String
    public var text: String
    public var isError: Bool
    /// Images of a tool's result, kept as read.
    public var images: JSONValue

    public init(id: String, created: Date, toolUseID: String, text: String, isError: Bool) {
        self.id = id
        self.created = created
        self.toolUseID = toolUseID
        self.text = text
        self.isError = isError
        images = []
    }
}

/// A call that waits for the user's permission: one the CLI asks about, or a change the app asks about
/// before it runs it (docs/ui/chat.md › Approval cards).
public struct PermissionRequestItem: Sendable, Hashable {
    public enum Decision: String, Sendable, Hashable {
        case allow, allowAlways, deny
    }

    public var id: String
    public var created: Date
    public var requestID: String
    /// The CLI's name of the tool: `mcp__hephaestus__add_comment`.
    public var toolName: String
    public var input: JSONValue
    public var reason: String?
    /// Nil while the request waits.
    public var decision: Decision?
    /// The Mac whose user answered; nil while it waits, and when the app cancelled it.
    public var decidedBy: String?

    public init(requestID: String, created: Date, toolName: String, input: JSONValue, reason: String? = nil) {
        id = "perm-\(requestID)"
        self.created = created
        self.requestID = requestID
        self.toolName = toolName
        self.input = input
        self.reason = reason
    }

    public var isPending: Bool { decision == nil }
}

/// A line from the app, such as an error.
public struct SystemItem: Sendable, Hashable {
    public enum Level: String, Sendable, Hashable {
        case info, warning, error
    }

    public var id: String
    public var created: Date
    public var text: String
    public var level: Level

    public init(id: String = UUID().uuidString, created: Date, text: String, level: Level = .info) {
        self.id = id
        self.created = created
        self.text = text
        self.level = level
    }
}

/// The end of a CLI turn.
public struct ResultItem: Sendable, Hashable {
    public var id: String
    public var created: Date
    public var durationMs: Int
    /// The cost, kept as the CLI reports it and not shown.
    public var costUSD: Double?
    public var isError: Bool
    /// Why the turn failed; nil for a turn that didn't.
    public var summary: String?

    public init(id: String = UUID().uuidString, created: Date, durationMs: Int, costUSD: Double? = nil, isError: Bool,
                summary: String? = nil) {
        self.id = id
        self.created = created
        self.durationMs = durationMs
        self.costUSD = costUSD
        self.isError = isError
        self.summary = summary
    }
}

// MARK: JSON

extension ChatItem {
    /// The item as a JSON object: `type`, `id`, `created`, then its own keys.
    public var json: JSONValue {
        func date(_ value: Date) -> JSONValue { .string(ISODate.string(from: value)) }
        func optional(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }
        switch self {
        case .user(let item):
            return ["type": "user", "id": .string(item.id), "created": date(item.created), "text": .string(item.text),
                    "attachments": .array(item.attachments.map(\.json)), "sender": .string(item.sender), "linkedItems": item.linkedItems,
                    "references": .array(item.references.map(\.json))]
        case .assistant(let item):
            return ["type": "assistant", "id": .string(item.id), "created": date(item.created), "text": .string(item.text),
                    "messageID": .string(item.messageID), "parentToolUseID": optional(item.parentToolUseID),
                    "model": optional(item.model), "effort": optional(item.effort?.rawValue)]
        case .thinking(let item):
            return ["type": "thinking", "id": .string(item.id), "created": date(item.created), "text": .string(item.text),
                    "parentToolUseID": optional(item.parentToolUseID)]
        case .toolUse(let item):
            return ["type": "toolUse", "id": .string(item.id), "created": date(item.created), "toolUseID": .string(item.toolUseID),
                    "name": .string(item.name), "server": optional(item.server), "input": item.input,
                    "parentToolUseID": optional(item.parentToolUseID)]
        case .toolResult(let item):
            return ["type": "toolResult", "id": .string(item.id), "created": date(item.created), "toolUseID": .string(item.toolUseID),
                    "text": .string(item.text), "isError": .bool(item.isError), "images": item.images]
        case .permissionRequest(let item):
            return ["type": "permissionRequest", "id": .string(item.id), "created": date(item.created),
                    "requestID": .string(item.requestID), "toolName": .string(item.toolName), "input": item.input,
                    "reason": optional(item.reason), "decision": optional(item.decision?.rawValue), "decidedBy": optional(item.decidedBy)]
        case .system(let item):
            return ["type": "system", "id": .string(item.id), "created": date(item.created), "text": .string(item.text),
                    "level": .string(item.level.rawValue)]
        case .result(let item):
            return ["type": "result", "id": .string(item.id), "created": date(item.created), "durationMs": .int(item.durationMs),
                    "costUSD": item.costUSD.map(JSONValue.double) ?? .null, "isError": .bool(item.isError),
                    "summary": optional(item.summary)]
        }
    }

    /// An item of a transcript line; nil for a type V3 doesn't read, or a required key missing.
    public init?(json: JSONValue) {
        guard let object = json.objectValue, let type = object["type"]?.stringValue, let id = object["id"]?.stringValue,
              let created = object["created"]?.stringValue.flatMap(ISODate.date(from:)) else { return nil }
        func string(_ key: String) -> String? { object[key]?.stringValue }
        func bool(_ key: String) -> Bool { object[key]?.boolValue ?? false }
        switch type {
        case "user":
            guard let text = string("text"), let sender = string("sender") else { return nil }
            var item = UserItem(id: id, created: created, text: text, sender: sender,
                                references: (object["references"]?.arrayValue ?? []).compactMap(ChatItemReference.init(json:)))
            item.attachments = (object["attachments"]?.arrayValue ?? []).compactMap(MessageAttachment.init(json:))
            item.linkedItems = object["linkedItems"] ?? []
            self = .user(item)
        case "assistant":
            guard let text = string("text"), let messageID = string("messageID") else { return nil }
            self = .assistant(AssistantItem(id: id, created: created, text: text, messageID: messageID,
                                            parentToolUseID: string("parentToolUseID"), model: string("model"),
                                            effort: string("effort").flatMap(Effort.init(rawValue:))))
        case "thinking":
            guard let text = string("text") else { return nil }
            self = .thinking(ThinkingItem(id: id, created: created, text: text, parentToolUseID: string("parentToolUseID")))
        case "toolUse":
            guard let toolUseID = string("toolUseID"), let name = string("name") else { return nil }
            self = .toolUse(ToolUseItem(id: id, created: created, toolUseID: toolUseID, name: name, server: string("server"),
                                        input: object["input"] ?? [:], parentToolUseID: string("parentToolUseID")))
        case "toolResult":
            guard let toolUseID = string("toolUseID") else { return nil }
            var item = ToolResultItem(id: id, created: created, toolUseID: toolUseID, text: string("text") ?? "", isError: bool("isError"))
            item.images = object["images"] ?? []
            self = .toolResult(item)
        case "permissionRequest":
            guard let requestID = string("requestID"), let toolName = string("toolName") else { return nil }
            var item = PermissionRequestItem(requestID: requestID, created: created, toolName: toolName, input: object["input"] ?? [:],
                                             reason: string("reason"))
            item.id = id
            item.decision = string("decision").flatMap(PermissionRequestItem.Decision.init(rawValue:))
            item.decidedBy = string("decidedBy")
            self = .permissionRequest(item)
        case "system":
            guard let text = string("text") else { return nil }
            self = .system(SystemItem(id: id, created: created, text: text,
                                      level: string("level").flatMap(SystemItem.Level.init(rawValue:)) ?? .info))
        case "result":
            guard let duration = object["durationMs"]?.intValue else { return nil }
            self = .result(ResultItem(id: id, created: created, durationMs: duration, costUSD: object["costUSD"]?.doubleValue,
                                      isError: bool("isError"), summary: string("summary")))
        default:
            return nil
        }
    }
}

extension ChatItemReference {
    var json: JSONValue {
        ["tool": .string(tool), "project": .string(projectID), "focus": .string(focus), "title": .string(title),
         "environment": environment.map(JSONValue.string) ?? .null]
    }

    init?(json: JSONValue) {
        guard let tool = json["tool"]?.stringValue, let project = json["project"]?.stringValue,
              let focus = json["focus"]?.stringValue, let title = json["title"]?.stringValue else { return nil }
        self.init(tool: tool, projectID: project, focus: focus, title: title, environment: json["environment"]?.stringValue)
    }
}
