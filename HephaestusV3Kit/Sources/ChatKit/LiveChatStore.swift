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
    let drafts = ChatDrafts()

    var cliStatus: ClaudeStatus? { session.status }
    /// How a tool words a call of the app's tool `name` with its input; nil for a tool the app doesn't have.
    private let describe: @MainActor (String, JSONValue) -> ToolCallText?

    public init(session: ChatSession, describe: @escaping @MainActor (String, JSONValue) -> ToolCallText?) {
        self.session = session
        self.describe = describe
    }

    /// The chat's project; nil for a chat the session doesn't know.
    public func projectID(of chatID: String) -> Project.ID? {
        session.chats[chatID]?.projectID
    }

    /// The chat's title; nil for a chat the session doesn't know.
    public func title(of chatID: String) -> String? {
        session.chats[chatID]?.file.title
    }

    func conversation(_ id: ChatConversation.ID?) -> ChatConversation? {
        guard let id, let chat = session.chats[id] else { return nil }
        var conversation = Self.conversation(chat)
        conversation.turns = turns(session.transcripts[id] ?? [], streaming: session.streaming[id], root: session.root(ofChat: id), chatID: id,
                                   isRunning: session.state(of: id).isRunning)
        conversation.waitingQuestions = session.waitingQuestions(in: id).map(ChatQuestionSet.init)
        conversation.compactions = session.compactions(in: id)
        conversation.isCompacting = session.compacting.contains(id)
        conversation.needsResume = session.needsResume(id)
        return conversation
    }

    func conversations(of projects: Set<Project.ID>) -> [ChatConversation] {
        session.chats(of: projects).map { chat in
            var conversation = Self.conversation(chat)
            conversation.mark = switch session.state(of: chat.id) {
            case .starting, .running: .working
            case .waitingPermission, .waitingAnswers: .waiting
            case .error: .error
            case .idle: nil
            }
            return conversation
        }
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
        case .idle, .waitingAnswers, .error: return nil
        }
    }

    var canStop: Bool { true }

    func send(_ text: String, to id: ChatConversation.ID?, project: Project, origin: ToolKind?, attachments: [ChatReference],
              files: [URL], reader: ToolReader) async throws(ChatSendError) -> ChatConversation.ID {
        // Every message carries one item: the one its chip shows, else the project.
        let references = attachments.isEmpty
            ? [ChatItemReference(tool: ChatItemReference.projectTool, projectID: project.id, focus: "", title: project.name)]
            : attachments.map { ChatItemReference(tool: $0.tool.rawValue, projectID: $0.projectID, focus: $0.focus, title: $0.title, environment: $0.environment) }
        do throws(ChatError) {
            return try await session.send(text, references: references, to: id, projectID: project.id, origin: origin?.rawValue, files: files)
        } catch {
            throw ChatSendError(message: error.description)
        }
    }

    func decide(_ approvalID: ChatApproval.ID, in conversationID: ChatConversation.ID, allow: Bool) {
        session.answer(conversationID, requestID: approvalID, allow: allow)
    }

    func decide(_ approvalID: ChatApproval.ID, in conversationID: ChatConversation.ID, answer: ChatApproval.Answer) {
        switch answer {
        case .allow: session.answer(conversationID, requestID: approvalID, decision: .allow)
        case .allowAlways: session.answer(conversationID, requestID: approvalID, decision: .allowAlways)
        case .deny(let message): session.answer(conversationID, requestID: approvalID, decision: .deny, message: message)
        }
    }

    func showing(_ id: ChatConversation.ID?, inKeyWindow: Bool, view: UUID) {
        session.showing(id, inKeyWindow: inKeyWindow, view: view)
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
                try session.setSettings(id, settings)
            } else {
                try session.setDefaults(model: settings.model, effort: settings.effort)
            }
        } catch {
            throw ChatSendError(message: error.description)
        }
    }

    func commands(for projectID: Project.ID) -> [ClaudeCommand] {
        session.commands(forProject: projectID)
    }

    func answer(_ answer: String, to label: String, inSet setID: ChatQuestionSet.ID, of id: ChatConversation.ID) async throws(ChatSendError) {
        do throws(ChatError) {
            try await session.answerQuestion(id, setID: setID, label: label, answer: answer)
        } catch {
            throw ChatSendError(message: error.description)
        }
    }

    // MARK: Turns

    static func conversation(_ chat: LoadedChat) -> ChatConversation {
        var conversation = ChatConversation(id: chat.id, projectID: chat.projectID, title: chat.file.title,
                                            origin: chat.file.origin.flatMap(ToolKind.init(rawValue:)), createdAt: chat.file.created, turns: [],
                                            updated: chat.file.updated)
        conversation.closed = chat.file.closed
        conversation.contextUsage = chat.file.contextUsage
        return conversation
    }

    func rename(_ id: ChatConversation.ID, to title: String) throws(ChatSendError) {
        do throws(ChatError) { try session.rename(id, to: title) } catch { throw ChatSendError(message: error.description) }
    }

    func close(_ id: ChatConversation.ID) throws(ChatSendError) {
        do throws(ChatError) { try session.close(id) } catch { throw ChatSendError(message: error.description) }
    }

    func reopen(_ id: ChatConversation.ID) throws(ChatSendError) {
        do throws(ChatError) { try session.reopen(id) } catch { throw ChatSendError(message: error.description) }
    }

    func delete(_ id: ChatConversation.ID) throws(ChatSendError) {
        do throws(ChatError) { try session.delete(id) } catch { throw ChatSendError(message: error.description) }
    }

    func resume(_ id: ChatConversation.ID) async throws(ChatSendError) {
        do throws(ChatError) { try await session.resume(id) } catch { throw ChatSendError(message: error.description) }
    }

    /// The transcript as turns: each message a turn of the user's, then what follows it a turn of Claude's,
    /// captioned with the model and effort of its first text. A call's row carries its input, its result and the
    /// work of the sub-agent it started (its steps); thinking shows folded; a turn that ended well ends with
    /// "Done · <duration>". `root` is the folder of the chat's project, which the file tools' rows and cards show paths
    /// from and the messages' files are read from; `chatID` finds the files of a feedback message that names
    /// them only; `isRunning` shows a spinner on the calls without a result.
    func turns(_ items: [ChatItem], streaming: StreamingText?, root: String? = nil, chatID: String? = nil, isRunning: Bool = false) -> [ChatTurn] {
        var turns: [ChatTurn] = []
        var results: [String: ToolResultItem] = [:]
        var steps: [String: [ChatItem]] = [:]
        for item in items {
            switch item {
            case .toolResult(let result): results[result.toolUseID] = result
            case .toolUse(let use): if let parent = use.parentToolUseID { steps[parent, default: []].append(item) }
            case .assistant(let text): if let parent = text.parentToolUseID { steps[parent, default: []].append(item) }
            case .thinking(let thinking): if let parent = thinking.parentToolUseID { steps[parent, default: []].append(item) }
            default: break
            }
        }

        func claude(_ id: String, _ date: Date) -> Int {
            if let last = turns.indices.last, turns[last].author == .claude { return last }
            turns.append(ChatTurn(id: id, author: .claude, date: date, blocks: []))
            return turns.count - 1
        }
        func add(_ block: ChatBlock, id: String, date: Date) {
            turns[claude(id, date)].blocks.append(block)
        }
        func fullCall(_ use: ToolUseItem) -> ChatToolCall {
            var row = call(use, root: root)
            let result = results[use.toolUseID]
            if let result {
                let firstLine = result.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
                if result.isError {
                    row.failed = true
                    row.detail = firstLine
                } else if row.reference == nil, row.detail == nil {
                    row.detail = firstLine
                }
            }
            var details = ChatToolDetails(name: use.name, server: use.server, input: Self.input(use), result: result?.text)
            details.resultImages = (result?.imageFiles ?? []).map { file in
                ChatMessageFile(id: file.id, name: file.name, contentType: UTType(mimeType: file.contentType), size: Int64(file.size),
                                url: root.flatMap { file.url(inProject: $0) })
            }
            details.isRunning = result == nil && isRunning
            details.steps = (steps[use.toolUseID] ?? []).compactMap { step in
                switch step {
                case .assistant(let text): ChatBlock(id: text.id, .text(text.text))
                case .thinking(let thinking): ChatBlock(id: thinking.id, .thinking(thinking.text))
                case .toolUse(let child): ChatBlock(id: child.id, .call(fullCall(child)))
                default: nil
                }
            }
            row.details = details
            return row
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
                                    blocks: message.text.isEmpty ? [] : [ChatBlock(id: "\(message.id).text", .text(message.text))])
                turn.files = Self.files(of: message, root: root, chatID: chatID)
                turns.append(turn)
            case .assistant(let text) where text.parentToolUseID == nil:
                add(ChatBlock(id: text.id, .text(text.text)), id: text.id, date: text.created)
                let turn = turns.count - 1
                if turns[turn].caption == nil, text.model != nil || text.effort != nil {
                    turns[turn].caption = ChatTurnCaption(model: text.model.map { ClaudeModel.name(of: $0, in: session.models) },
                                                          effort: text.effort.map(ReplySettingsRows.title))
                }
            case .thinking(let thinking) where thinking.parentToolUseID == nil:
                add(ChatBlock(id: thinking.id, .thinking(thinking.text)), id: thinking.id, date: thinking.created)
            case .toolUse(let use) where use.parentToolUseID == nil:
                add(ChatBlock(id: use.id, .call(fullCall(use))), id: use.id, date: use.created)
            case .permissionRequest(let request):
                add(ChatBlock(id: request.id, .approval(approval(request, root: root))), id: request.id, date: request.created)
            case .questions(let set):
                add(ChatBlock(id: set.id, .questions(ChatQuestionSet(set))), id: set.id, date: set.created)
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
            case .result(let end) where !end.isError:
                // V2's footer, without the cost the owner left out: "Done · 34 s".
                let duration = Duration.milliseconds(end.durationMs).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
                add(ChatBlock(id: end.id, .notice(ChatNotice(text: String(localized: "Done · \(duration)", bundle: #bundle,
                                                                          comment: "The end of Claude's turn and how long it took"),
                                                             level: .done))), id: end.id, date: end.created)
            default:
                break
            }
        }
        if let streaming, !items.contains(where: { $0.id == streaming.itemID }) {
            add(ChatBlock(id: streaming.itemID, .text(streaming.text)), id: streaming.itemID, date: Date())
        }
        return turns
    }

    /// A call's input as its row shows it, as V2's cards did: a shell command, an edit's old and new text, a
    /// written file's content highlighted by its extension, otherwise the input as JSON.
    static func input(_ use: ToolUseItem) -> [ChatToolInput] {
        let input = use.input
        func string(_ key: String) -> String? { input[key]?.stringValue }
        let fileExtension = string("file_path").map { ($0 as NSString).pathExtension.lowercased() }.flatMap { $0.isEmpty ? nil : $0 }
        if use.server == nil {
            switch use.name {
            case "Bash":
                if let command = string("command") { return [ChatToolInput(text: command, language: "shell")] }
            case "Edit":
                if let old = string("old_string"), let new = string("new_string") {
                    return [ChatToolInput(title: String(localized: "Old", bundle: #bundle, comment: "The text an edit replaces"), text: old, language: fileExtension),
                            ChatToolInput(title: String(localized: "New", bundle: #bundle, comment: "The text an edit writes"), text: new, language: fileExtension)]
                }
            case "Write":
                if let content = string("content") { return [ChatToolInput(text: content, language: fileExtension)] }
            default:
                break
            }
        }
        return [ChatToolInput(text: pretty(input) ?? "{}", language: "json")]
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
        case .allow?: .allowed
        case .allowAlways?: .allowedAlways
        // A refusal nobody gave is the app's: Stop, the process's end, quitting.
        case .deny?: request.decidedBy == nil ? .cancelled : .declined
        case nil: nil
        }
        let split = ToolUseItem.split(request.toolName)
        var card: ChatApproval
        if split.server == MCPProtocol.serverName, let text = describe(split.name, request.input) {
            let reference = text.item.flatMap(Self.reference)
            let channel = text.item.map { item in
                ToolKind(rawValue: item.tool).map(ChatApproval.Channel.init) ?? .projects
            }
            card = ChatApproval(id: request.requestID,
                                request: text.request ?? String(localized: "Claude wants to use \(split.name)", bundle: #bundle),
                                preview: text.preview, reference: reference, channel: channel, decision: decision)
        } else if split.server == nil, let text = FileToolText.request(split.name, input: request.input, root: root) {
            card = ChatApproval(id: request.requestID, request: text.request, preview: text.preview, reference: nil, channel: nil, decision: decision)
            if split.name == "Edit", let old = request.input["old_string"]?.stringValue, let new = request.input["new_string"]?.stringValue {
                card.edit = (old, new)
            }
        } else {
            card = ChatApproval(id: request.requestID, request: String(localized: "Claude wants to use \(split.name)", bundle: #bundle),
                                preview: Self.cliPreview(split.name, input: request.input), reference: nil, channel: nil, decision: decision)
        }
        card.decidedBy = request.decidedBy
        card.reason = request.reason
        card.isCLI = split.server != MCPProtocol.serverName
        return card
    }

    /// A CLI tool's card preview, as V2's: a command then its description, a URL then its prompt, a plan; any
    /// other input as JSON.
    static func cliPreview(_ name: String, input: JSONValue) -> String? {
        switch name {
        case "Bash":
            if let command = input["command"]?.stringValue {
                return [command, input["description"]?.stringValue].compactMap { $0 }.joined(separator: "\n\n")
            }
        case "WebFetch":
            if let url = input["url"]?.stringValue {
                return [url, input["prompt"]?.stringValue].compactMap { $0 }.joined(separator: "\n\n")
            }
        case "ExitPlanMode":
            if let plan = input["plan"]?.stringValue { return plan }
        default:
            break
        }
        return pretty(input)
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
