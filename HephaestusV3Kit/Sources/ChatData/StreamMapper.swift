import Foundation
import MCPKit

/// What one line of the CLI's stream-json output means for the chat (docs/data.md › Stream mapping).
public enum StreamOutput: Sendable, Hashable {
    /// An item to add, or to put in place of the item with its id.
    case item(ChatItem)
    /// Text streamed into the text block that will become the item `itemID`.
    case delta(itemID: String, text: String)
    /// `system/init`: a CLI turn opens. `first` for the first of the process; `mcpProblem` says why the app's
    /// MCP server isn't usable in the session (`failed`, `missing`…), nil when it is.
    case cliTurnOpened(first: Bool, mcpProblem: String?)
    /// `command_lifecycle`: what the CLI did with the message whose line had `uuid`.
    case commandState(uuid: String, state: String)
    /// `can_use_tool`: the CLI asks before a call, with its `permission_suggestions`, the rules Always Allow keeps.
    case permissionRequest(PermissionRequestItem, suggestions: JSONValue?)
    /// Another control request, which the app refuses.
    case unsupportedControlRequest(requestID: String, subtype: String)
    /// The answer to one of the app's control requests.
    case controlResponse(requestID: String, success: Bool, response: JSONValue?, error: String?)
    /// The CLI withdraws a permission request.
    case cancelRequest(requestID: String)
    /// The images of a tool's result, after its item, to store as the result's files.
    case toolResultImages(toolUseID: String, images: [ResultImage])
    /// The end of a CLI turn, after the open blocks were finished as items.
    case result(ResultItem)
    case compactionStarted
    case compactionEnded
    /// `system/status`'s `permissionMode`: the mode the CLI is in after changing it itself (leaving Plan Only
    /// after its card), in the CLI's words (`default` for Ask Every Time).
    case permissionMode(String)
    /// `background_tasks_changed`: the ids of the background tasks still running (docs/data.md › Background work).
    case backgroundTasks([String])
    /// `task_notification`: a task ended, its result going to Claude.
    case taskNotification(taskID: String)
    /// `task_started`, `task_progress`, `task_updated` and `task_notification`, for the chat's workflows and agents.
    case taskLine(JSONValue)
    /// `rate_limit_event` with the weekly window: the Claude account's weekly usage (docs/data.md › Plan usage file).
    case planUsage(PlanUsage)
    /// A line of a known shape that changes nothing; the name of its type, for the log.
    case ignored(String)
    /// A line that isn't a JSON object.
    case invalid
}

/// Maps the CLI's output lines to transcript items and events, keeping the blocks being streamed. One per
/// process.
public struct StreamMapper: Sendable {
    /// The chat's effort, recorded with each text block of a model that has an effort setting.
    public var effort: Effort?
    /// Set by Stop: the next result that is an error is the stop's.
    public var stopping = false
    private let now: @Sendable () -> Date

    private struct Block: Sendable {
        var type: String
        var text = ""
        var final = false
    }

    /// Blocks by message id, then index.
    private var blocks: [String: [Int: Block]] = [:]
    /// The message each `message_start` opened, by `parent_tool_use_id` ("" for the main conversation).
    private var latestMessage: [String: String] = [:]
    private var models: [String: String] = [:]
    private var initialized = false
    private var compacting = false

    /// The longest string kept in a tool call's input or result.
    public static let maximumLength = 100_000

    public init(effort: Effort? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.effort = effort
        self.now = now
    }

    /// The outputs of one line.
    public mutating func map(_ line: Data) -> [StreamOutput] {
        guard let value = try? JSONValue.parse(line), let object = value.objectValue else { return [.invalid] }
        let type = object["type"]?.stringValue ?? ""
        switch type {
        case "system": return mapSystem(object)
        case "stream_event": return mapStreamEvent(object)
        case "assistant": return mapAssistant(object)
        case "user": return mapUser(object)
        case "control_request":
            guard let id = object["request_id"]?.stringValue, let request = object["request"] else { return [.ignored(type)] }
            let subtype = request["subtype"]?.stringValue ?? ""
            guard subtype == "can_use_tool", let tool = request["tool_name"]?.stringValue else {
                return [.unsupportedControlRequest(requestID: id, subtype: subtype)]
            }
            let reason = request["decision_reason"]?.stringValue.map(Self.withoutANSI)
            return [.permissionRequest(PermissionRequestItem(requestID: id, created: now(), toolName: tool,
                                                             input: request["input"] ?? [:], reason: reason),
                                       suggestions: request["permission_suggestions"])]
        case "control_response":
            guard let response = object["response"], let id = response["request_id"]?.stringValue else { return [.ignored(type)] }
            let success = response["subtype"]?.stringValue == "success"
            return [.controlResponse(requestID: id, success: success, response: response["response"], error: response["error"]?.stringValue)]
        case "control_cancel_request":
            guard let id = object["request_id"]?.stringValue else { return [.ignored(type)] }
            return [.cancelRequest(requestID: id)]
        case "result":
            return mapResult(object)
        case "command_lifecycle":
            guard let uuid = object["command_uuid"]?.stringValue, let state = object["state"]?.stringValue else { return [.ignored(type)] }
            return [.commandState(uuid: uuid, state: state)]
        case "rate_limit_event":
            guard let usage = PlanUsage.report(object["rate_limit_info"]) else { return [.ignored(type)] }
            return [.planUsage(usage)]
        default:
            return [.ignored(type)]
        }
    }

    /// Finishes the open blocks: a text or thinking block that has text and no item yet becomes one; a tool call
    /// still streaming is dropped. At a result, and when the process exits.
    public mutating func finish() -> [ChatItem] {
        var items: [ChatItem] = []
        for messageID in blocks.keys.sorted() {
            for (index, block) in (blocks[messageID] ?? [:]).sorted(by: { $0.key < $1.key }) where !block.final && !block.text.isEmpty {
                let id = Self.itemID(messageID, index)
                switch block.type {
                case "text":
                    items.append(.assistant(AssistantItem(id: id, created: now(), text: block.text, messageID: messageID,
                                                          model: models[messageID], effort: effortOf(models[messageID]))))
                case "thinking":
                    items.append(.thinking(ThinkingItem(id: id, created: now(), text: block.text)))
                default:
                    break
                }
            }
        }
        blocks = [:]
        latestMessage = [:]
        models = [:]
        return items
    }

    // MARK: Lines

    private mutating func mapSystem(_ line: [String: JSONValue]) -> [StreamOutput] {
        switch line["subtype"]?.stringValue {
        case "init":
            let first = !initialized
            initialized = true
            return [.cliTurnOpened(first: first, mcpProblem: first ? Self.mcpProblem(line["mcp_servers"]) : nil)]
        case "status":
            var outputs: [StreamOutput] = []
            if let mode = line["permissionMode"]?.stringValue {
                outputs.append(.permissionMode(mode))
            }
            if line["status"]?.stringValue == "compacting" {
                if !compacting {
                    compacting = true
                    outputs.append(.compactionStarted)
                }
                return outputs
            }
            if compacting {
                compacting = false
                outputs.append(.compactionEnded)
            }
            return outputs.isEmpty ? [.ignored("system/status")] : outputs
        case "compact_boundary":
            guard let metadata = line["compact_metadata"], let trigger = metadata["trigger"]?.stringValue,
                  let tokens = metadata["pre_tokens"]?.intValue, tokens >= 0 else { return [.ignored("system/compact_boundary")] }
            let how = switch trigger {
            case "auto": "automatic"
            default: trigger
            }
            return [.item(.system(SystemItem(created: now(), text: "Conversation compacted (\(how), \(Self.tokens(tokens)) tokens before)")))]
        case "background_tasks_changed":
            let ids = (line["tasks"]?.arrayValue ?? []).compactMap { $0["task_id"]?.stringValue }
            return [.backgroundTasks(ids)]
        case "task_notification":
            guard let id = line["task_id"]?.stringValue else { return [.ignored("system/task_notification")] }
            return [.taskNotification(taskID: id), .taskLine(.object(line))]
        case "task_started", "task_progress", "task_updated":
            return [.taskLine(.object(line))]
        case let subtype:
            return [.ignored("system/\(subtype ?? "")")]
        }
    }

    private mutating func mapStreamEvent(_ line: [String: JSONValue]) -> [StreamOutput] {
        guard let event = line["event"] else { return [] }
        let parent = line["parent_tool_use_id"]?.stringValue ?? ""
        switch event["type"]?.stringValue {
        case "message_start":
            if let id = event["message"]?["id"]?.stringValue {
                latestMessage[parent] = id
                if let model = event["message"]?["model"]?.stringValue { models[id] = model }
            }
            return []
        case "content_block_start":
            guard let messageID = messageID(of: line, parent: parent), let index = event["index"]?.intValue,
                  let type = event["content_block"]?["type"]?.stringValue else { return [] }
            blocks[messageID, default: [:]][index] = Block(type: type)
            return []
        case "content_block_delta":
            guard let messageID = messageID(of: line, parent: parent), let index = event["index"]?.intValue,
                  let delta = event["delta"], var block = blocks[messageID]?[index], !block.final else { return [] }
            let text: String? = switch delta["type"]?.stringValue {
            case "text_delta": delta["text"]?.stringValue
            case "thinking_delta": delta["thinking"]?.stringValue
            default: nil
            }
            guard let text, !text.isEmpty else { return [] }
            block.text += text
            blocks[messageID]?[index] = block
            return block.type == "text" && parent.isEmpty ? [.delta(itemID: Self.itemID(messageID, index), text: text)] : []
        default:
            return []
        }
    }

    private func messageID(of line: [String: JSONValue], parent: String) -> String? {
        line["api_message_id"]?.stringValue ?? latestMessage[parent]
    }

    private mutating func mapAssistant(_ line: [String: JSONValue]) -> [StreamOutput] {
        guard let message = line["message"], let messageID = message["id"]?.stringValue,
              let content = message["content"]?.arrayValue else { return [.ignored("assistant")] }
        let parent = line["parent_tool_use_id"]?.stringValue
        let model = message["model"]?.stringValue ?? models[messageID]
        var outputs: [StreamOutput] = []
        for block in content {
            let type = block["type"]?.stringValue ?? ""
            let index = claim(messageID: messageID, type: type)
            let id = Self.itemID(messageID, index)
            switch type {
            case "text":
                if let text = block["text"]?.stringValue, !text.isEmpty {
                    outputs.append(.item(.assistant(AssistantItem(id: id, created: now(), text: text, messageID: messageID,
                                                                  parentToolUseID: parent, model: model, effort: effortOf(model)))))
                }
            case "thinking":
                if let text = block["thinking"]?.stringValue, !text.isEmpty {
                    outputs.append(.item(.thinking(ThinkingItem(id: id, created: now(), text: text, parentToolUseID: parent))))
                }
            case "tool_use":
                guard let toolUseID = block["id"]?.stringValue, let name = block["name"]?.stringValue else { continue }
                let split = ToolUseItem.split(name)
                outputs.append(.item(.toolUse(ToolUseItem(id: id, created: now(), toolUseID: toolUseID, name: split.name,
                                                          server: split.server, input: Self.truncated(block["input"] ?? [:]),
                                                          parentToolUseID: parent))))
            default:
                break
            }
        }
        return outputs
    }

    /// The index of a finished block: the first open block of the message with its type and no item yet, else
    /// the next index of the message (a block that wasn't streamed).
    private mutating func claim(messageID: String, type: String) -> Int {
        var known = blocks[messageID] ?? [:]
        let index = known.filter { $0.value.type == type && !$0.value.final }.keys.min() ?? ((known.keys.max() ?? -1) + 1)
        var block = known[index] ?? Block(type: type)
        block.final = true
        known[index] = block
        blocks[messageID] = known
        return index
    }

    private func mapUser(_ line: [String: JSONValue]) -> [StreamOutput] {
        guard let content = line["message"]?["content"]?.arrayValue else { return [.ignored("user")] }
        let results = content.filter { $0["type"]?.stringValue == "tool_result" }
        guard !results.isEmpty else { return [.ignored("user")] }
        return results.flatMap { block -> [StreamOutput] in
            guard let toolUseID = block["tool_use_id"]?.stringValue else { return [] }
            let text: String
            var images: [ResultImage] = []
            switch block["content"] {
            case .string(let value):
                text = value
            case .array(let parts):
                let texts = parts.filter { $0["type"]?.stringValue == "text" }.compactMap { $0["text"]?.stringValue }
                let others = parts.filter { !["text", "image"].contains($0["type"]?.stringValue ?? "") }.map(\.text)
                text = (texts + others).joined(separator: "\n")
                images = parts.filter { $0["type"]?.stringValue == "image" }.compactMap { part in
                    guard part["source"]?["type"]?.stringValue == "base64", let media = part["source"]?["media_type"]?.stringValue,
                          let data = part["source"]?["data"]?.stringValue.flatMap({ Data(base64Encoded: $0) }) else { return nil }
                    return ResultImage(mediaType: media, data: data)
                }
            default:
                text = ""
            }
            let item = StreamOutput.item(.toolResult(ToolResultItem(id: "\(toolUseID)#result", created: now(), toolUseID: toolUseID,
                                                                    text: Self.truncated(text), isError: block["is_error"]?.boolValue ?? false)))
            return images.isEmpty ? [item] : [item, .toolResultImages(toolUseID: toolUseID, images: images)]
        }
    }

    private mutating func mapResult(_ line: [String: JSONValue]) -> [StreamOutput] {
        var outputs = finish().map(StreamOutput.item)
        if compacting {
            compacting = false
            outputs.append(.compactionEnded)
        }
        let isError = line["is_error"]?.boolValue ?? false
        var summary: String?
        if isError {
            if stopping {
                summary = "Stopped by the user."
            } else if line["subtype"]?.stringValue == "success", let result = line["result"]?.stringValue {
                summary = result
            } else if let errors = line["errors"]?.arrayValue?.compactMap(\.stringValue), !errors.isEmpty {
                summary = errors.joined(separator: "\n")
            } else {
                summary = line["subtype"]?.stringValue
            }
        }
        stopping = false
        outputs.append(.result(ResultItem(created: now(), durationMs: line["duration_ms"]?.intValue ?? 0,
                                          costUSD: line["total_cost_usd"]?.doubleValue, isError: isError, summary: summary)))
        return outputs
    }

    // MARK: Helpers

    private func effortOf(_ model: String?) -> Effort? {
        model == nil ? nil : effort
    }

    /// `<message id>#<block index>`.
    public static func itemID(_ messageID: String, _ index: Int) -> String {
        "\(messageID)#\(index)"
    }

    /// Why the app's server isn't usable, from `system/init`'s `mcp_servers`: its `status` when it is `failed`,
    /// `needs-auth` or `disabled`, `missing` without it; nil when it is usable.
    static func mcpProblem(_ servers: JSONValue?) -> String? {
        guard let server = servers?.arrayValue?.first(where: { $0["name"]?.stringValue == MCPProtocol.serverName }) else {
            return "missing"
        }
        let status = server["status"]?.stringValue ?? ""
        return ["failed", "needs-auth", "disabled"].contains(status) ? status : nil
    }

    /// `24.6K`, `967K`, `1.2M`: one decimal under 100, none from 100.
    static func tokens(_ count: Int) -> String {
        func short(_ value: Double, _ unit: String) -> String {
            let text = value < 100 ? String(format: "%.1f", value) : String(format: "%.0f", value)
            return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + unit
        }
        if count < 1000 { return "\(count)" }
        if count < 1_000_000 { return short(Double(count) / 1000, "K") }
        return short(Double(count) / 1_000_000, "M")
    }

    static func withoutANSI(_ text: String) -> String {
        text.replacing(/\u{1B}\[[0-9;?]*[ -\/]*[@-~]/, with: "")
    }

    /// A string longer than `maximumLength` cut, with the number of characters removed.
    static func truncated(_ text: String) -> String {
        guard text.count > maximumLength else { return text }
        return String(text.prefix(maximumLength)) + "… [truncated \(text.count - maximumLength) characters]"
    }

    static func truncated(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let text): .string(truncated(text))
        case .array(let values): .array(values.map(truncated))
        case .object(let values): .object(values.mapValues(truncated))
        default: value
        }
    }
}

/// An image of a tool's result, as the CLI wrote it: its MIME type and its bytes.
public struct ResultImage: Sendable, Hashable {
    public var mediaType: String
    public var data: Data

    public init(mediaType: String, data: Data) {
        self.mediaType = mediaType
        self.data = data
    }

    /// The extension of its file: `png`, `jpg`, `gif`, `webp`, or what the type's subtype says.
    var fileExtension: String {
        switch mediaType {
        case "image/jpeg": "jpg"
        default: mediaType.split(separator: "/").last.map(String.init) ?? "png"
        }
    }
}
