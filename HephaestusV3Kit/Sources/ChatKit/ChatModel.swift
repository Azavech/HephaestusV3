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
    /// Claude's questions waiting for the user's answers, which the card over the composer asks.
    var waitingQuestions: ChatQuestionSet?
    /// Claude's picker request waiting for the user's answer, which its card over the composer asks.
    var waitingPicker: PickerItem?
    /// Closed, as V2's Close left it: listed only while closed chats show, its composer replaced.
    var closed = false
    /// A ticket's, bundle's, CI or feedback chat: its item lists it, the panel's Chats pop-up doesn't, as V2's didn't.
    var isItemChat = false
    /// What the list's row marks: work, a wait for the user, or an error; nil when idle.
    var mark: ChatMark?
    /// How much of the context the conversation used, as the CLI last said.
    var contextUsage: ContextUsage?
    /// How many times the CLI compacted it.
    var compactions = 0
    /// The CLI compacts it now.
    var isCompacting = false
    /// It stopped with an error Resume goes on from.
    var needsResume = false

    var updatedAt: Date { updated ?? turns.last?.date ?? createdAt }

    /// The cards waiting for the user, the oldest first.
    var pendingApprovals: [ChatApproval] {
        turns.flatMap(\.blocks).compactMap { block in
            if case .approval(let approval) = block.content, approval.decision == nil { return approval }
            return nil
        }
    }

    /// The conversation as plain text, for Copy Conversation: each turn's author, then its text and its calls'
    /// actions, turns a blank line apart.
    var plainText: String {
        turns.map { turn in
            let author = turn.author == .user ? String(localized: "You", bundle: #bundle) : String(localized: "Claude", bundle: #bundle)
            let lines = turn.blocks.compactMap { block -> String? in
                switch block.content {
                case .text(let text): text
                case .call(let call): "· " + call.action
                case .approval(let approval): "· " + approval.request
                case .notice(let notice): "· " + notice.text
                case .questions(let set): set.questions.map { "\($0.label). \($0.question)" }.joined(separator: "\n")
                case .thinking: nil
                case .images(let caption, let files): ([caption].compactMap { $0 } + files.map { "· " + $0.name }).joined(separator: "\n")
                case .picker(let request): request.question
                }
            }
            return ([author] + lines).joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

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

/// A chat's state, as the list marks it, as V2's rows did: a spinner, an orange dot or a red dot.
enum ChatMark: Hashable {
    /// Claude starts or works.
    case working
    /// A card, questions or a picker request wait for the user.
    case waiting
    case error
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
    /// Claude's model and effort, for the turn's caption; nil for the user's turns and the samples.
    var caption: ChatTurnCaption?
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
        /// Questions Claude asked the user, with their answers so far.
        case questions(ChatQuestionSet)
        /// Claude's thinking, shown folded.
        case thinking(String)
        /// Images Claude showed with `show_image`, under their Markdown caption.
        case images(caption: String?, files: [ChatMessageFile])
        /// A symbol, color, sound, shortcut, font or animation Claude asked the user to choose, with its answer.
        case picker(PickerItem)

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
    /// What the row shows once expanded: its input, its result and its steps; nil when it has none (samples).
    var details: ChatToolDetails?
}

/// A call as its expanded row shows it, as V2's tool cards did (docs/ui/chat.md › Tool-call rows).
struct ChatToolDetails: Hashable {
    /// The tool's own name: `Bash`, or `get_ticket` for an MCP tool.
    var name: String
    /// The MCP server, `hephaestus` for the app's tools; nil for a tool of the CLI.
    var server: String?
    /// The input, as one or more sections.
    var input: [ChatToolInput]
    /// Nil until the result comes.
    var result: String?
    /// The images the result returned.
    var resultImages: [ChatMessageFile] = []
    /// The work of the sub-agent the call started: its text, calls and thinking, in order.
    var steps: [ChatBlock] = []
    /// No result yet, and the chat is still working.
    var isRunning = false
}

/// A section of a call's input: a title (`Old`, `New`) or none, the text, and the language that highlights it.
struct ChatToolInput: Hashable {
    var title: String?
    var text: String
    /// `shell`, `json`, a file's extension; nil for plain text.
    var language: String?
}

/// What a turn's caption shows after the author: the model and effort of Claude's reply.
struct ChatTurnCaption: Hashable {
    /// `Opus 5.5`.
    var model: String?
    /// `Extra High`.
    var effort: String?
}

/// Questions Claude asked with `ask_questions`, as a conversation shows them.
struct ChatQuestionSet: Identifiable, Hashable {
    /// The set's id.
    let id: String
    var questions: [ChatQuestion]
    /// By question label.
    var answers: [String: String]
    var completed: Bool

    init(id: String, questions: [ChatQuestion], answers: [String: String] = [:], completed: Bool = false) {
        self.id = id
        self.questions = questions
        self.answers = answers
        self.completed = completed
    }

    init(_ item: QuestionsItem) {
        self.init(id: item.questionSetID, questions: item.questions, answers: item.answers, completed: item.completed)
    }

    /// The first question without an answer, in label order; the first one when all have.
    var firstUnanswered: Int {
        questions.firstIndex { answers[$0.label] == nil } ?? 0
    }

    /// The next question without an answer after `index`, wrapping, other than `index` itself and `answered`.
    func nextUnanswered(after index: Int, answered: String) -> Int? {
        guard !questions.isEmpty else { return nil }
        for step in 1..<max(questions.count, 1) + 1 {
            let candidate = (index + step) % questions.count
            let label = questions[candidate].label
            if candidate != index, label != answered, answers[label] == nil { return candidate }
        }
        return nil
    }

    /// Whether answering the question at `index` completes the set: every other one has an answer.
    func completes(at index: Int) -> Bool {
        questions.indices.allSatisfy { $0 == index || answers[questions[$0].label] != nil }
    }
}

/// A line from the app in a conversation.
struct ChatNotice: Hashable {
    enum Level: Hashable {
        /// `done` is the end of a turn that went well: a quiet line.
        case info, warning, error, done
    }

    let text: String
    let level: Level
}

/// A change Claude wants to make through a tool, waiting for the user.
struct ChatApproval: Identifiable, Hashable {
    enum Decision: Hashable {
        case allowed
        /// Allowed, with the CLI keeping its suggested rules.
        case allowedAlways
        case declined
        /// Refused by the app, not the user: Stop, the process's end, quitting.
        case cancelled
    }

    /// What the user answers.
    enum Answer: Hashable {
        case allow
        case allowAlways
        /// With an optional message, which Claude reads as the call's error.
        case deny(String?)
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
    /// The Mac whose user answered.
    var decidedBy: String?
    /// Why the CLI asks, as it says.
    var reason: String?
    /// The CLI's own request, which Always Allow can answer with the CLI's rules.
    var isCLI = false
    /// An edit's replaced and new text, which the card shows as a diff.
    var edit: (old: String, new: String)? {
        get { editTexts.map { ($0[0], $0[1]) } }
        set { editTexts = newValue.map { [$0.old, $0.new] } }
    }
    private var editTexts: [String]?

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
