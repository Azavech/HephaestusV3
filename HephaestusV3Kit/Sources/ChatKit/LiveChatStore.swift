import ChatData
import SwiftUI
import Foundation
import MCPKit
import ToolsFoundation
import UniformTypeIdentifiers

/// The app's chats, on the Claude CLI (docs/ui/chat.md): each conversation is a chat of `ChatSession`, its
/// turns made from the chat's transcript, the tools' calls worded by the tools.
public final class LiveChatStore: ChatStore {
    public let session: ChatSession
    /// How a tool words a call of the app's tool `name` with its input; nil for a tool the app doesn't have.
    private let describe: @MainActor (String, JSONValue) -> ToolCallText?

    public init(session: ChatSession, describe: @escaping @MainActor (String, JSONValue) -> ToolCallText?) {
        self.session = session
        self.describe = describe
    }

    func conversation(_ id: ChatConversation.ID?) -> ChatConversation? {
        guard let id, let chat = session.chats[id] else { return nil }
        var conversation = Self.conversation(chat)
        conversation.turns = turns(session.transcripts[id] ?? [], streaming: session.streaming[id], root: session.root(ofChat: id), chatID: id)
        return conversation
    }

    func conversations(of projects: Set<Project.ID>) -> [ChatConversation] {
        session.chats(of: projects).map(Self.conversation)
    }

    func open(_ id: ChatConversation.ID) async {
        await session.open(id)
    }

    func activity(_ id: ChatConversation.ID?) -> ChatActivity? {
        guard let id else { return nil }
        let since = session.turnStarts[id] ?? Date()
        switch session.state(of: id) {
        case .starting: return .starting
        case .running: return session.compacting.contains(id) ? .compacting(since: since) : .working(since: since)
        case .waitingPermission: return .waiting
        case .idle, .error: return nil
        }
    }

    var canStop: Bool { true }

    func send(_ text: String, to id: ChatConversation.ID?, project: Project, origin: ToolKind?, attachments: [ChatReference],
              reader: ToolReader) async throws(ChatSendError) -> ChatConversation.ID {
        // Every message carries one item: the one its chip shows, else the project.
        let references = attachments.isEmpty
            ? [ChatItemReference(tool: ChatItemReference.projectTool, projectID: project.id, focus: "", title: project.name)]
            : attachments.map { ChatItemReference(tool: $0.tool.rawValue, projectID: $0.projectID, focus: $0.focus, title: $0.title, environment: $0.environment) }
        do throws(ChatError) {
            return try await session.send(text, references: references, to: id, projectID: project.id, origin: origin?.rawValue)
        } catch {
            throw ChatSendError(message: error.description)
        }
    }

    func decide(_ approvalID: ChatApproval.ID, in conversationID: ChatConversation.ID, allow: Bool) {
        session.answer(conversationID, requestID: approvalID, allow: allow)
    }

    func stop(_ id: ChatConversation.ID) {
        session.stop(id)
    }

    var models: [ClaudeModel] { session.models }

    func replySettings(of id: ChatConversation.ID?) -> ChatSettings? {
        guard let id else { return session.defaults }
        return session.chats[id]?.file.settings
    }

    func setReplySettings(_ settings: ChatSettings, of id: ChatConversation.ID?) throws(ChatSendError) {
        do throws(ChatError) {
            if let id {
                try session.setSettings(id, model: settings.model, effort: settings.effort)
            } else {
                try session.setDefaults(model: settings.model, effort: settings.effort)
            }
        } catch {
            throw ChatSendError(message: error.description)
        }
    }

    // MARK: Turns

    static func conversation(_ chat: LoadedChat) -> ChatConversation {
        ChatConversation(id: chat.id, projectID: chat.projectID, title: chat.file.title, origin: chat.file.origin.flatMap(ToolKind.init(rawValue:)),
                         createdAt: chat.file.created, turns: [], updated: chat.file.updated)
    }

    /// The transcript as turns: each message a turn of the user's, then what follows it a turn of Claude's.
    /// Sub-agents' work, thinking, and the results of turns that ended well don't show.
    /// `root` is the folder of the chat's project, which the file tools' rows and cards show paths from and the
    /// messages' files are read from; `chatID` finds the files of a feedback message that names them only.
    func turns(_ items: [ChatItem], streaming: StreamingText?, root: String? = nil, chatID: String? = nil) -> [ChatTurn] {
        var turns: [ChatTurn] = []
        /// Where each call's row is, by the CLI's tool use id.
        var calls: [String: (turn: Int, block: Int)] = [:]

        func claude(_ id: String, _ date: Date) -> Int {
            if let last = turns.indices.last, turns[last].author == .claude { return last }
            turns.append(ChatTurn(id: id, author: .claude, date: date, blocks: []))
            return turns.count - 1
        }
        func add(_ block: ChatBlock, id: String, date: Date) {
            turns[claude(id, date)].blocks.append(block)
        }

        for item in items {
            switch item {
            case .user(let message):
                let attachments = message.references.compactMap { reference -> ChatReference? in
                    guard let tool = ToolKind(rawValue: reference.tool) else { return nil }
                    return ChatReference(tool: tool, projectID: reference.projectID, focus: reference.focus, title: reference.title,
                                         environment: reference.environment)
                }
                var turn = ChatTurn(id: message.id, author: .user, date: message.created, attachments: attachments,
                                    blocks: [ChatBlock(id: "\(message.id).text", .text(message.text))])
                turn.files = Self.files(of: message, root: root, chatID: chatID)
                turns.append(turn)
            case .assistant(let text) where text.parentToolUseID == nil:
                add(ChatBlock(id: text.id, .text(text.text)), id: text.id, date: text.created)
            case .toolUse(let use) where use.parentToolUseID == nil:
                add(ChatBlock(id: use.id, .call(call(use, root: root))), id: use.id, date: use.created)
                let turn = turns.count - 1
                calls[use.toolUseID] = (turn, turns[turn].blocks.count - 1)
            case .toolResult(let result):
                guard let place = calls[result.toolUseID],
                      case .call(var call) = turns[place.turn].blocks[place.block].content else { break }
                let firstLine = result.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
                if result.isError {
                    call.failed = true
                    call.detail = firstLine
                } else if call.reference == nil, call.detail == nil {
                    call.detail = firstLine
                }
                turns[place.turn].blocks[place.block].content = .call(call)
            case .permissionRequest(let request):
                add(ChatBlock(id: request.id, .approval(approval(request, root: root))), id: request.id, date: request.created)
            case .system(let line):
                let level: ChatNotice.Level = switch line.level {
                case .info: .info
                case .warning: .warning
                case .error: .error
                }
                add(ChatBlock(id: line.id, .notice(ChatNotice(text: line.text, level: level))), id: line.id, date: line.created)
            case .result(let end) where end.isError && end.summary != "Stopped by the user.":
                let text = end.summary ?? String(localized: "Claude's turn ended with an error.", bundle: #bundle)
                add(ChatBlock(id: end.id, .notice(ChatNotice(text: text, level: .error))), id: end.id, date: end.created)
            default:
                break
            }
        }
        if let streaming, !items.contains(where: { $0.id == streaming.itemID }) {
            add(ChatBlock(id: streaming.itemID, .text(streaming.text)), id: streaming.itemID, date: Date())
        }
        return turns
    }

    /// A message's files, read from the project's `.hephaestus/`; those a feedback message of 1.0.31 to 1.0.33
    /// names in its text when it has none.
    static func files(of message: UserItem, root: String?, chatID: String?) -> [ChatMessageFile] {
        guard let root else { return [] }
        var attachments = message.attachments
        if attachments.isEmpty, let chatID {
            attachments = FeedbackReport.files(inMessage: message.text, chatID: chatID, root: root)
        }
        return attachments.map { attachment in
            ChatMessageFile(id: attachment.id, name: attachment.name, contentType: UTType(mimeType: attachment.contentType),
                            size: attachment.size > 0 ? Int64(attachment.size) : nil, url: attachment.url(inProject: root))
        }
    }

    private func call(_ use: ToolUseItem, root: String?) -> ChatToolCall {
        if use.server == nil, let call = FileToolText.call(use.name, input: use.input, root: root) {
            return call
        }
        if use.server == MCPProtocol.serverName {
            let text = describe(use.name, use.input)
            return ChatToolCall(action: text?.action ?? String(localized: "Used \(use.name)", bundle: #bundle, comment: "A call of a tool, by its name"),
                                reference: text?.item.flatMap(Self.reference))
        }
        return ChatToolCall(action: String(localized: "Used \(use.name)", bundle: #bundle, comment: "A call of a tool, by its name"), reference: nil)
    }

    private func approval(_ request: PermissionRequestItem, root: String?) -> ChatApproval {
        let decision: ChatApproval.Decision? = switch request.decision {
        case .allow?, .allowAlways?: .allowed
        case .deny?: .declined
        case nil: nil
        }
        let split = ToolUseItem.split(request.toolName)
        if split.server == MCPProtocol.serverName, let text = describe(split.name, request.input) {
            let reference = text.item.flatMap(Self.reference)
            let channel = text.item.map { item in
                ToolKind(rawValue: item.tool).map(ChatApproval.Channel.init) ?? .projects
            }
            return ChatApproval(id: request.requestID,
                                request: text.request ?? String(localized: "Claude wants to use \(split.name)", bundle: #bundle),
                                preview: text.preview, reference: reference, channel: channel, decision: decision)
        }
        if split.server == nil, let text = FileToolText.request(split.name, input: request.input, root: root) {
            return ChatApproval(id: request.requestID, request: text.request, preview: text.preview, reference: nil, channel: nil,
                                decision: decision)
        }
        return ChatApproval(id: request.requestID, request: String(localized: "Claude wants to use \(split.name)", bundle: #bundle),
                            preview: Self.pretty(request.input), reference: nil, channel: nil, decision: decision)
    }

    /// The item of a tool's call, as a chat names it; a project's has none (no tool window shows it alone).
    static func reference(_ item: ToolItem) -> ChatReference? {
        ToolKind(rawValue: item.tool).map { ChatReference(tool: $0, projectID: item.projectID, focus: item.focus, title: item.title) }
    }

    /// A call's input as JSON with two-space indentation.
    static func pretty(_ input: JSONValue) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: input.foundation, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self).replacing("    ", with: "  ")
    }
}

/// The app's chats, given to every window by ToolsScenes; nil in previews.
extension EnvironmentValues {
    @Entry public var chatStore: LiveChatStore?
}
