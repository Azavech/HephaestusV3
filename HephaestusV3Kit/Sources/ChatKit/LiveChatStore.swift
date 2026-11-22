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

    /// Whether an existing chat holds an unsent draft: the automatic restart for an update waits until none does
    /// (docs/ui/updates.md › Restart rules).
    /// Unsent drafts of chats that still exist: a deleted chat's can't be sent or lost, so it never holds the
    /// automatic restart for an update.
    public var hasDrafts: Bool { drafts.ids.contains { session.chats[$0] != nil } }

    var cliStatus: ClaudeStatus? { session.status }

    /// The CLI keeps a message written during a turn, and runs it after.
    var queuesMessages: Bool { true }

    func agentRows(of id: ChatConversation.ID) -> [ChatAgentRow] {
        let records = session.agents(of: id)
        // V2 hid Resume while the agent's chat is closed: resuming it would reopen the chat without a word.
        let closed = session.chats[id]?.file.closed == true
        let works = [.starting, .running, .waitingPermission].contains(session.state(of: id))
        func row(_ agent: ChatAgent) -> ChatAgentRow {
            let workflow = agent.workflowID.flatMap { workflowID in records.workflows.first { $0.id == workflowID } }
            return ChatAgentRow(id: agent.id, chatID: id, kind: agent.kind == .workflow ? .workflowAgent : .subagent, title: agent.title,
                                phase: agent.phase, name: nil, state: agent.state, workflowID: agent.workflowID,
                                canResume: agent.kind == .subagent && (agent.state == .failed || agent.state == .stopped) && agent.taskID != nil
                                    && !closed,
                                workflowRuns: workflow?.state == .running, chatWorks: works)
        }
        var rows: [ChatAgentRow] = []
        for workflow in records.workflows {
            rows.append(ChatAgentRow(id: workflow.id, chatID: id, kind: .workflow, title: workflow.summary, phase: nil, name: workflow.name,
                                     state: workflow.state, workflowID: workflow.id, canResume: false, workflowRuns: workflow.state == .running))
            rows += records.agents.filter { $0.workflowID == workflow.id }.map(row)
        }
        rows += records.agents.filter { $0.kind == .subagent }.map(row)
        return rows
    }

    /// An agent's conversation, made again only when the chat's transcript, the agent's own items, the folder,
    /// the running or the models changed: its view reads it at each redraw.
    func agentConversation(_ row: ChatAgentRow) -> ChatConversation {
        let key = MadeAgentKey(revision: session.transcripts.revision(of: row.chatID), count: session.agentTranscripts[row.id]?.count ?? 0,
                               root: session.root(ofChat: row.chatID), isRunning: row.state == .running, models: session.models)
        if let found = madeAgents[row.id], found.key == key { return found.conversation }
        let conversation = makeAgentConversation(row)
        if madeAgents[row.id] == nil, madeAgents.count >= Self.keptMade { madeAgents.removeAll() }
        madeAgents[row.id] = (key, conversation)
        return conversation
    }

    private func makeAgentConversation(_ row: ChatAgentRow) -> ChatConversation {
        var conversation = ChatConversation(id: row.tag, projectID: session.chats[row.chatID]?.projectID ?? "", title: row.title, origin: nil,
                                            createdAt: Date(), turns: [])
        // A sub-agent's own items are its view's top level; those of agents it started stay steps of their calls.
        let items = session.agentTranscript(row.id, in: row.chatID).map { item -> ChatItem in
            switch item {
            case .assistant(var text) where text.parentToolUseID == row.id:
                text.parentToolUseID = nil
                return .assistant(text)
            case .thinking(var thinking) where thinking.parentToolUseID == row.id:
                thinking.parentToolUseID = nil
                return .thinking(thinking)
            case .toolUse(var use) where use.parentToolUseID == row.id:
                use.parentToolUseID = nil
                return .toolUse(use)
            default:
                return item
            }
        }
        conversation.turns = turns(items, streaming: nil, root: session.root(ofChat: row.chatID),
                                   chatID: row.chatID, isRunning: row.state == .running)
        return conversation
    }

    func openAgent(_ agentID: String, in chatID: ChatConversation.ID) async {
        await session.openAgent(agentID, in: chatID)
    }

    func stopWorkflow(_ workflowID: String, in chatID: ChatConversation.ID) {
        session.stopWorkflow(workflowID, in: chatID)
    }

    func resumeAgent(_ agentID: String, in chatID: ChatConversation.ID) async throws(ChatSendError) {
        do throws(ChatError) { try await session.resumeAgent(agentID, in: chatID) } catch { throw ChatSendError(message: error.description) }
    }
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

    /// The chat with its turns, made from its transcript once per change of the transcript, of its project's folder,
    /// of its running or of the models (`made(_:)`); the text streaming is added to them at each read.
    func conversation(_ id: ChatConversation.ID?) -> ChatConversation? {
        guard let id, let chat = session.chats[id] else { return nil }
        var conversation = Self.conversation(chat)
        let parts = made(id)
        conversation.turns = Self.appending(session.streaming[id], to: parts.turns, isRecorded: parts.itemIDs.contains)
        conversation.waitingQuestions = parts.waitingQuestions
        conversation.waitingPicker = parts.waitingPicker
        conversation.compactions = parts.compactions
        conversation.isCompacting = session.compacting.contains(id)
        conversation.needsResume = session.needsResume(id)
        return conversation
    }

    /// What a chat's transcript gives its conversation, and what it was made from.
    struct MadeTurns {
        /// The transcript's revision (`PerChat.revision(of:)`), the project's folder, the chat's running and the models.
        struct Key: Equatable {
            var revision: Int
            var root: String?
            var isRunning: Bool
            var models: [ClaudeModel]
        }

        var key: Key
        var turns: [ChatTurn]
        var itemIDs: Set<String>
        var waitingQuestions: ChatQuestionSet?
        var waitingPicker: PickerItem?
        var compactions: Int
    }

    /// The conversations made, by chat. A view reads its chat's conversation at each change of what it shows, and
    /// once for each of its parts: making the turns of a long transcript each time held the main thread, typing
    /// included.
    private var madeTurns: [String: MadeTurns] = [:]
    /// The chats kept made at most: past them, those kept are dropped, and made again when they show.
    private static let keptMade = 16
    /// The agents' conversations made, by agent id, with what they were made from.
    private var madeAgents: [String: (key: MadeAgentKey, conversation: ChatConversation)] = [:]

    private struct MadeAgentKey: Equatable {
        var revision: Int
        var count: Int
        var root: String?
        var isRunning: Bool
        var models: [ClaudeModel]
    }

    /// The chat's turns and what else its transcript gives, made again only when the transcript, the folder, the
    /// running or the models changed. Observes the transcript, as reading it does.
    func made(_ id: ChatConversation.ID) -> MadeTurns {
        let key = MadeTurns.Key(revision: session.transcripts.revision(of: id), root: session.root(ofChat: id),
                                isRunning: session.state(of: id).isRunning, models: session.models)
        if let found = madeTurns[id], found.key == key { return found }
        let items = session.transcripts[id] ?? []
        let new = MadeTurns(key: key, turns: turns(items, streaming: nil, root: key.root, chatID: id, isRunning: key.isRunning),
                            itemIDs: Set(items.map(\.id)), waitingQuestions: session.waitingQuestions(in: id).map(ChatQuestionSet.init),
                            waitingPicker: session.waitingPicker(in: id), compactions: session.compactions(in: id))
        if madeTurns[id] == nil, madeTurns.count >= Self.keptMade { madeTurns.removeAll() }
        madeTurns[id] = new
        return new
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

    func answerPicker(_ answer: String, request requestID: String, of id: ChatConversation.ID) async throws(ChatSendError) {
        do throws(ChatError) {
            try await session.answerPicker(id, requestID: requestID, answer: answer)
        } catch {
            throw ChatSendError(message: error.description)
        }
    }

    func pickerCatalogs(of id: ChatConversation.ID) -> PickerCatalogAccess {
        let session = session
        return PickerCatalogAccess(
            symbols: { await session.catalogs.symbols() },
            sounds: { await session.pickerCatalogs(.sound, for: id).sounds },
            fonts: { await session.pickerCatalogs(.font, for: id).fonts }
        )
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
        ChatFiles.clean(drafts.files(of: id))
        drafts.forget(id)
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
                // The first line only: a result can hold 100,000 characters, and the turns are made again at
                // each item a running chat records.
                func firstLine() -> String {
                    result.text.split(maxSplits: 1, whereSeparator: \.isNewline).first.map(String.init) ?? ""
                }
                if result.isError {
                    row.failed = true
                    row.detail = firstLine()
                } else if row.reference == nil, row.detail == nil {
                    row.detail = firstLine()
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
            case .picker(let request):
                add(ChatBlock(id: request.id, .picker(request)), id: request.id, date: request.created)
            case .images(let shown):
                // At the place of the call, in the main conversation whatever agent made it, as V2.
                let files = shown.images.map { image in
                    ChatMessageFile(id: image.id, name: image.name, contentType: UTType(mimeType: image.contentType),
                                    size: image.size > 0 ? Int64(image.size) : nil, url: root.flatMap(image.url(inProject:)))
                }
                add(ChatBlock(id: shown.id, .images(caption: shown.caption, files: files)), id: shown.id, date: shown.created)
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
        return Self.appending(streaming, to: turns) { id in items.contains { $0.id == id } }
    }

    /// The turns with the text streaming at the end of Claude's last turn, or of a new one; unchanged without text, or
    /// once its item is recorded.
    static func appending(_ streaming: StreamingText?, to turns: [ChatTurn], isRecorded: (String) -> Bool) -> [ChatTurn] {
        guard let streaming, !isRecorded(streaming.itemID) else { return turns }
        var turns = turns
        let block = ChatBlock(id: streaming.itemID, .text(streaming.text))
        if let last = turns.indices.last, turns[last].author == .claude {
            turns[last].blocks.append(block)
        } else {
            turns.append(ChatTurn(id: streaming.itemID, author: .claude, date: Date(), blocks: [block]))
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
        if use.server == nil, let call = CLIToolText.call(use.name, input: use.input) {
            return call
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
            let title = split.server == nil ? CLIToolText.request(split.name, input: request.input) : nil
            card = ChatApproval(id: request.requestID, request: title ?? String(localized: "Claude wants to use \(split.name)", bundle: #bundle),
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
