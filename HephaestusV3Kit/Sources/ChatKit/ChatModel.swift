import Foundation
import ToolsFoundation

/// A conversation with Claude about a project. Claude reads items through their tools and asks before
/// it changes anything; the conversation keeps what it read, so the user sees it and can open it.
struct ChatConversation: Identifiable, Hashable {
    let id: String
    let projectID: Project.ID
    var title: String
    /// The tool window whose side panel started it; nil when it started in the Chat window.
    let origin: ToolKind?
    let createdAt: Date
    var turns: [ChatTurn]

    var updatedAt: Date { turns.last?.date ?? createdAt }

    /// Every item the conversation attached or read, in the order it first came up.
    var references: [ChatReference] {
        var seen: Set<ChatReference.ID> = []
        var result: [ChatReference] = []
        for turn in turns {
            let read = turn.blocks.compactMap { block -> ChatReference? in
                if case .toolCall(let reference, _) = block.content { return reference }
                return nil
            }
            for reference in turn.attachments + read where seen.insert(reference.id).inserted {
                result.append(reference)
            }
        }
        return result
    }
}

/// One turn: the user's message with what it attached, or Claude's reply.
struct ChatTurn: Identifiable, Hashable {
    enum Author: Hashable {
        case user
        case claude
    }

    /// Stable for the conversation's life, as a model's message id is: `chat-checkout.2`.
    let id: String
    let author: Author
    let date: Date
    var attachments: [ChatReference] = []
    var blocks: [ChatBlock]
    /// A reply of the sample engine, which stands in until a model is connected.
    var isSample = false

    init(
        id: String = UUID().uuidString, author: Author, date: Date, attachments: [ChatReference] = [],
        blocks: [ChatBlock], isSample: Bool = false
    ) {
        self.id = id
        self.author = author
        self.date = date
        self.attachments = attachments
        self.blocks = blocks
        self.isSample = isSample
    }
}

/// A piece of a turn.
struct ChatBlock: Identifiable, Hashable {
    enum Content: Hashable {
        case text(String)
        /// An item Claude read through its tool, and what the tool said.
        case toolCall(ChatReference, ToolReading)
        /// A change Claude asks to make; nothing changes until the user allows it.
        case approval(ChatApproval)
    }

    let id: UUID
    var content: Content

    init(id: UUID = UUID(), _ content: Content) {
        self.id = id
        self.content = content
    }
}

/// A change Claude wants to make through a tool, waiting for the user.
struct ChatApproval: Identifiable, Hashable {
    enum Decision: Hashable {
        case allowed
        case declined
    }

    /// A change Claude can ask to make. Each is worded as a whole sentence, so a translation can order
    /// its words as its language needs.
    enum Change: Hashable {
        /// A comment added to the item, a ticket.
        case comment
    }

    /// Stable for the conversation's life, as a model's tool call is: `chat-checkout.comment`.
    let id: String
    let change: Change
    /// The item it would change.
    let reference: ChatReference
    /// What it would write.
    let preview: String
    var decision: Decision?

    /// "Claude wants to comment on ORD-142".
    var request: String {
        switch change {
        case .comment: String(localized: "Claude wants to comment on \(reference.title)", bundle: #bundle)
        }
    }
}

/// What Claude may do without asking, set in Settings and in the Chat window's inspector.
enum ChangePermission: String, CaseIterable, Identifiable {
    case never
    case askFirst
    case always

    var id: Self { self }

    var title: String {
        switch self {
        case .never: String(localized: "Never", bundle: #bundle, comment: "A permission: Claude may never do it")
        case .askFirst: String(localized: "Ask First", bundle: #bundle, comment: "A permission: Claude asks before doing it")
        case .always: String(localized: "Always", bundle: #bundle, comment: "A permission: Claude may always do it")
        }
    }
}

/// The chat's preferences, kept in the user defaults.
public enum ChatPreferences {
    /// Whether tool windows offer the chat panel at all. Off, the panel and its button are gone.
    public static let showsPanelKey = "chat.showsPanel"
    static let ticketChangesKey = "chat.ticketChanges"
    static let buildStartsKey = "chat.buildStarts"
}
