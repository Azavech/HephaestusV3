import Foundation
import Observation
import ToolsFoundation

/// Every conversation of the app, shared by the Chat windows and the tool windows' side panels: a chat
/// started beside a ticket is listed in the Chat window too. Its `engine` answers the messages.
///
/// Conversations last as long as the app runs; the samples come back at each launch.
@Observable
public final class ChatStore {
    public static let shared = ChatStore()

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

    /// A store with the samples only, for previews and captures.
    public static func transient() -> ChatStore {
        ChatStore()
    }

    func conversation(_ id: ChatConversation.ID?) -> ChatConversation? {
        conversations.first { $0.id == id }
    }

    /// The conversations of these projects, the latest first.
    func conversations(of projects: Set<Project.ID>) -> [ChatConversation] {
        conversations.filter { projects.contains($0.projectID) }.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Whether the conversation waits for a reply.
    func isResponding(_ id: ChatConversation.ID?) -> Bool {
        id.map(responding.contains) ?? false
    }

    /// Sends `text` with `attachments` to the conversation, or to a new one about `project` when `id`
    /// names none, and asks the engine for the reply. Returns the conversation's id; nil when the text
    /// is empty or only whitespace.
    ///
    /// A new conversation's title is the message's first 80 characters, and `origin` is the tool beside
    /// which it started.
    @discardableResult
    func send(
        _ text: String, to id: ChatConversation.ID?, project: Project, origin: ToolKind?,
        attachments: [ChatReference], reader: ToolReader
    ) -> ChatConversation.ID? {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return nil }
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

    /// The user's answer to a change Claude asked to make.
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

    private func update(_ id: ChatConversation.ID, _ change: (inout ChatConversation) -> Void) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        change(&conversations[index])
    }
}
