import ChatData
import Foundation
import ToolsFoundation
import UniformTypeIdentifiers

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
    /// The last change, as the chat's file has it; nil takes the last turn's date.
    var updated: Date?

    var updatedAt: Date { updated ?? turns.last?.date ?? createdAt }

    /// Every item the conversation attached or read, in the order it first came up.
    var references: [ChatReference] {
        var seen: Set<ChatReference.ID> = []
        var result: [ChatReference] = []
        for turn in turns {
            let read = turn.blocks.compactMap { block -> ChatReference? in
                if case .call(let call) = block.content { return call.reference }
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
    /// The files the user's message carried, such as a feedback's screenshot.
    var files: [ChatMessageFile] = []
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

/// A file a message carried, as the turn shows it: an image as a thumbnail, another file as a chip.
struct ChatMessageFile: Identifiable, Hashable {
    let id: String
    let name: String
    let contentType: UTType?
    /// Nil when unknown.
    let size: Int64?
    /// Nil when the message's path breaks the rule of message files; the file itself may be missing.
    let url: URL?
}

/// A piece of a turn.
struct ChatBlock: Identifiable, Hashable {
    enum Content: Hashable {
        /// What the user or Claude wrote; Claude's is Markdown.
        case text(String)
        /// A call of a tool: what it read or changed, and the way to its window.
        case call(ChatToolCall)
        /// A change Claude asks to make; nothing changes until the user allows it.
        case approval(ChatApproval)
        /// A line from the app, such as an error of the Claude CLI.
        case notice(ChatNotice)

        /// An item Claude read through its tool, and what the tool said.
        static func toolCall(_ reference: ChatReference, _ reading: ToolReading) -> Content {
            .call(ChatToolCall(action: reading.action, reference: reference, detail: reading.detail))
        }
    }

    let id: String
    var content: Content

    init(id: String = UUID().uuidString, _ content: Content) {
        self.id = id
        self.content = content
    }
}

/// A call of a tool by Claude, as its tool words it.
struct ChatToolCall: Hashable {
    /// `Read ticket ORD-142`.
    let action: String
    /// The item it read or changed; nil when it has none, such as a list of projects.
    let reference: ChatReference?
    /// The gist: the tool's one-line answer, or the error. Nil asks the item's tool for its answer.
    var detail: String?
    var failed = false
}

/// A line from the app in a conversation.
struct ChatNotice: Hashable {
    enum Level: Hashable {
        case info, warning, error
    }

    let text: String
    let level: Level
}

/// A change Claude wants to make through a tool, waiting for the user.
struct ChatApproval: Identifiable, Hashable {
    enum Decision: Hashable {
        case allowed
        case declined
    }

    /// The request's id, stable for the conversation's life: `chat-checkout.comment`.
    let id: String
    /// The request as one sentence, worded by the tool so that a translation orders its words as its language
    /// needs: "Claude wants to comment on ORD-142".
    let request: String
    /// What it would write; nil when the change writes nothing to show.
    let preview: String?
    /// The item it would change, if one.
    let reference: ChatReference?
    /// The tool it goes through; nil for a tool of the Claude CLI.
    let channel: Channel?
    var decision: Decision?

    /// A tool of the app, as the card names it.
    struct Channel: Hashable {
        let title: String
        let symbol: String

        init(title: String, symbol: String) {
            self.title = title
            self.symbol = symbol
        }

        init(_ tool: ToolKind) {
            self.init(title: tool.title, symbol: tool.symbol)
        }

        /// The Projects window's tools.
        static var projects: Channel {
            Channel(title: String(localized: "Projects", bundle: #bundle, comment: "The Projects window, as a tool"), symbol: "folder")
        }
    }

    init(id: String, request: String, preview: String?, reference: ChatReference?, channel: Channel?, decision: Decision? = nil) {
        self.id = id
        self.request = request
        self.preview = preview
        self.reference = reference
        self.channel = channel
        self.decision = decision
    }

    /// A comment Claude wants to add to a ticket.
    static func comment(id: String, on reference: ChatReference, preview: String, decision: Decision? = nil) -> ChatApproval {
        ChatApproval(id: id, request: String(localized: "Claude wants to comment on \(reference.title)", bundle: #bundle),
                     preview: preview, reference: reference, channel: Channel(reference.tool), decision: decision)
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
    static let projectChangesKey = "chat.projectChanges"
    static let apiCallsKey = "chat.apiCalls"
    static let clusterChangesKey = "chat.clusterChanges"
    static let machineChangesKey = "chat.machineChanges"
    static let buildStartsKey = "chat.buildStarts"
    static let fileEditsKey = "chat.fileEdits"

    /// Settings ▸ Chat › Edit the project's files; Ask First until the user sets it.
    public static func fileEdits(_ defaults: UserDefaults = .standard) -> ChatFileEdits {
        defaults.string(forKey: fileEditsKey).flatMap(ChatFileEdits.init(rawValue:)) ?? .askFirst
    }
}
