import ChatData
import Foundation
import Observation
import ToolsFoundation

/// Every conversation of the app, shared by the Chat windows and the tool windows' side panels: a chat
/// started beside a ticket is listed in the Chat window too. The app's is `LiveChatStore`, on the Claude CLI;
/// previews use `SampleChatStore`.
protocol ChatStore: AnyObject {
    func conversation(_ id: ChatConversation.ID?) -> ChatConversation?
    /// The conversations of these projects, the latest first. Their turns may be left out: `conversation(_:)`
    /// gives them.
    func conversations(of projects: Set<Project.ID>) -> [ChatConversation]
    /// Reads the conversation's turns, when they aren't read yet.
    func open(_ id: ChatConversation.ID) async
    /// What Claude is doing in the conversation; nil when nothing.
    func activity(_ id: ChatConversation.ID?) -> ChatActivity?
    /// Whether Claude's turns can be stopped.
    var canStop: Bool { get }
    /// Sends `text` with `attachments` to the conversation, or to a new one about `project` when `id` names
    /// none, and returns the conversation's id. Throws why it can't, as the user reads it.
    func send(_ text: String, to id: ChatConversation.ID?, project: Project, origin: ToolKind?, attachments: [ChatReference],
              reader: ToolReader) async throws(ChatSendError) -> ChatConversation.ID
    /// The user's answer to a change Claude asked to make.
    func decide(_ approvalID: ChatApproval.ID, in conversationID: ChatConversation.ID, allow: Bool)
    func stop(_ id: ChatConversation.ID)
    /// The models Claude can answer with; empty when no model is connected (the samples).
    var models: [ClaudeModel] { get }
    /// The model and effort of the conversation, or of new chats when `id` is nil; nil without models.
    func replySettings(of id: ChatConversation.ID?) -> ChatSettings?
    func setReplySettings(_ settings: ChatSettings, of id: ChatConversation.ID?) throws(ChatSendError)
}

/// Why a message wasn't sent, or a setting not changed: the sentence the composer shows.
struct ChatSendError: Error, Hashable {
    let message: String
}

/// The sample conversations and engine, for previews and captures: they come back at each launch, and new
/// ones last as long as the app runs.
@Observable
final class SampleChatStore: ChatStore {
    private(set) var conversations: [ChatConversation]
    /// The conversations waiting for a reply.
    private(set) var responding: Set<ChatConversation.ID> = []

    private let engine: any ChatEngine
    /// The replies on their way, by conversation.
    @ObservationIgnored private var replies: [ChatConversation.ID: Task<Void, Never>] = [:]

    init(conversations: [ChatConversation] = ChatConversation.samples, engine: any ChatEngine = SampleChatEngine()) {
        self.conversations = conversations
        self.engine = engine
    }

    /// A store with the samples only.
    static func transient() -> SampleChatStore {
        SampleChatStore()
    }

    func conversation(_ id: ChatConversation.ID?) -> ChatConversation? {
        conversations.first { $0.id == id }
    }

    func conversations(of projects: Set<Project.ID>) -> [ChatConversation] {
        conversations.filter { projects.contains($0.projectID) }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func open(_ id: ChatConversation.ID) async {}

    func activity(_ id: ChatConversation.ID?) -> ChatActivity? {
        id.map(responding.contains) == true ? .reading : nil
    }

    var canStop: Bool { false }

    /// A new conversation's title is the message's first 80 characters, and `origin` is the tool beside which
    /// it started.
    func send(_ text: String, to id: ChatConversation.ID?, project: Project, origin: ToolKind?, attachments: [ChatReference],
              reader: ToolReader) throws(ChatSendError) -> ChatConversation.ID {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { throw ChatSendError(message: "") }
        let now = Date()
        let conversationID: ChatConversation.ID
        if let id, conversations.contains(where: { $0.id == id }) {
            conversationID = id
        } else {
            conversationID = UUID().uuidString
            conversations.append(ChatConversation(
                id: conversationID, projectID: project.id, title: String(message.prefix(80)), origin: origin, createdAt: now, turns: []
            ))
        }
        update(conversationID) {
            $0.turns.append(ChatTurn(author: .user, date: now, attachments: attachments, blocks: [ChatBlock(.text(message))]))
        }
        responding.insert(conversationID)
        let engine = engine
        replies[conversationID] = Task {
            let blocks = await engine.reply(to: message, attachments: attachments, project: project, reader: reader)
            update(conversationID) {
                $0.turns.append(ChatTurn(author: .claude, date: Date(), blocks: blocks, isSample: engine.repliesAreSamples))
            }
            responding.remove(conversationID)
            replies[conversationID] = nil
        }
        return conversationID
    }

    /// Waits until every reply on its way has arrived.
    func repliesArrived() async {
        for reply in Array(replies.values) {
            await reply.value
        }
    }

    func decide(_ approvalID: ChatApproval.ID, in conversationID: ChatConversation.ID, allow: Bool) {
        update(conversationID) { conversation in
            for turnIndex in conversation.turns.indices {
                for blockIndex in conversation.turns[turnIndex].blocks.indices {
                    if case .approval(var approval) = conversation.turns[turnIndex].blocks[blockIndex].content, approval.id == approvalID {
                        approval.decision = allow ? .allowed : .declined
                        conversation.turns[turnIndex].blocks[blockIndex].content = .approval(approval)
                    }
                }
            }
        }
    }

    func stop(_ id: ChatConversation.ID) {}

    var models: [ClaudeModel] { [] }

    func replySettings(of id: ChatConversation.ID?) -> ChatSettings? { nil }

    func setReplySettings(_ settings: ChatSettings, of id: ChatConversation.ID?) throws(ChatSendError) {}

    private func update(_ id: ChatConversation.ID, _ change: (inout ChatConversation) -> Void) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        change(&conversations[index])
    }
}
