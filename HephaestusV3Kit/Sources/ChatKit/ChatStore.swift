import ChatData
import Foundation
import Observation
import ToolsFoundation
import UniformTypeIdentifiers

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
    /// Sends `text` with `attachments` and `files` to the conversation, or to a new one about `project` when `id`
    /// names none, and returns the conversation's id. Throws why it can't, as the user reads it.
    func send(_ text: String, to id: ChatConversation.ID?, project: Project, origin: ToolKind?, attachments: [ChatReference],
              files: [URL], reader: ToolReader) async throws(ChatSendError) -> ChatConversation.ID
    /// The user's answer to a change Claude asked to make.
    func decide(_ approvalID: ChatApproval.ID, in conversationID: ChatConversation.ID, allow: Bool)
    /// The card's answer: Allow, Always Allow, or Don't Allow with a message for Claude.
    func decide(_ approvalID: ChatApproval.ID, in conversationID: ChatConversation.ID, answer: ChatApproval.Answer)
    func stop(_ id: ChatConversation.ID)
    /// The models Claude can answer with; empty when no model is connected (the samples).
    var models: [ClaudeModel] { get }
    /// The model and effort of the conversation, or of new chats when `id` is nil; nil without models.
    func replySettings(of id: ChatConversation.ID?) -> ChatSettings?
    func setReplySettings(_ settings: ChatSettings, of id: ChatConversation.ID?) throws(ChatSendError)
    /// The slash commands a chat of the project can run, for the composer's suggestions.
    func commands(for projectID: Project.ID) -> [ClaudeCommand]
    /// The user's answer to the question `label` of the set Claude asked in the conversation. Throws why it
    /// wasn't taken, as the user reads it.
    func answer(_ answer: String, to label: String, inSet setID: ChatQuestionSet.ID, of id: ChatConversation.ID) async throws(ChatSendError)
    func rename(_ id: ChatConversation.ID, to title: String) throws(ChatSendError)
    /// Closes the conversation, once its turn ends when one runs.
    func close(_ id: ChatConversation.ID) throws(ChatSendError)
    func reopen(_ id: ChatConversation.ID) throws(ChatSendError)
    /// Deletes the conversation: its files go to the Trash.
    func delete(_ id: ChatConversation.ID) throws(ChatSendError)
    /// Goes on after an error, through the internal skill `resume-chat`.
    func resume(_ id: ChatConversation.ID) async throws(ChatSendError)
    /// What a view shows, and whether its window is the key window: a chat shown there gets no notification.
    func showing(_ id: ChatConversation.ID?, inKeyWindow: Bool, view: UUID)
    /// Each chat's unsent text and files, shared by its views.
    var drafts: ChatDrafts { get }
    /// The Claude CLI's state, for the line over the composer; nil without a CLI (the samples).
    var cliStatus: ClaudeStatus? { get }
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
    let drafts = ChatDrafts()
    /// The samples have no CLI; previews set a state to show its line.
    var cliStatus: ClaudeStatus?
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
              files: [URL], reader: ToolReader) throws(ChatSendError) -> ChatConversation.ID {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty || !files.isEmpty else { throw ChatSendError(message: "") }
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
            var turn = ChatTurn(author: .user, date: now, attachments: attachments, blocks: message.isEmpty ? [] : [ChatBlock(.text(message))])
            turn.files = files.map { ChatMessageFile(id: UUID().uuidString, name: $0.lastPathComponent, contentType: UTType(filenameExtension: $0.pathExtension),
                                                     size: nil, url: $0) }
            $0.turns.append(turn)
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

    /// Stores the answer; the last one ends the set and sends the answers as the user's message.
    func answer(_ answer: String, to label: String, inSet setID: ChatQuestionSet.ID, of id: ChatConversation.ID) async throws(ChatSendError) {
        update(id) { conversation in
            guard var set = conversation.waitingQuestions, set.id == setID else { return }
            set.answers[label] = answer
            set.completed = set.questions.allSatisfy { set.answers[$0.label] != nil }
            for turn in conversation.turns.indices {
                for block in conversation.turns[turn].blocks.indices {
                    if case .questions(let shown) = conversation.turns[turn].blocks[block].content, shown.id == setID {
                        conversation.turns[turn].blocks[block].content = .questions(set)
                    }
                }
            }
            if set.completed {
                conversation.waitingQuestions = nil
                let item = QuestionsItem(id: set.id, created: Date(), questionSetID: set.id, questions: set.questions, answers: set.answers)
                conversation.turns.append(ChatTurn(author: .user, date: Date(), blocks: [ChatBlock(.text(item.answersMessage()))]))
            } else {
                conversation.waitingQuestions = set
            }
        }
    }

    func decide(_ approvalID: ChatApproval.ID, in conversationID: ChatConversation.ID, answer: ChatApproval.Answer) {
        if case .deny = answer {
            decide(approvalID, in: conversationID, allow: false)
        } else {
            decide(approvalID, in: conversationID, allow: true)
        }
    }

    func rename(_ id: ChatConversation.ID, to title: String) throws(ChatSendError) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ChatSendError(message: "title: use 1 to 100 characters on one line.") }
        update(id) { $0.title = trimmed }
    }

    func close(_ id: ChatConversation.ID) throws(ChatSendError) { update(id) { $0.closed = true } }

    func reopen(_ id: ChatConversation.ID) throws(ChatSendError) { update(id) { $0.closed = false } }

    func delete(_ id: ChatConversation.ID) throws(ChatSendError) {
        conversations.removeAll { $0.id == id }
    }

    func resume(_ id: ChatConversation.ID) async throws(ChatSendError) {
        update(id) { $0.needsResume = false }
    }

    /// Two skills, for the previews of the composer's suggestions.
    func commands(for projectID: Project.ID) -> [ClaudeCommand] {
        [ClaudeCommand(name: "hephaestus-skills:report-feedback", description: "Turns feedback about the app into tickets."),
         ClaudeCommand(name: "release-notes", description: "Writes the release notes of a version.")]
    }

    private func update(_ id: ChatConversation.ID, _ change: (inout ChatConversation) -> Void) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        change(&conversations[index])
    }
}

extension ChatStore {
    /// The samples post no notification.
    func showing(_ id: ChatConversation.ID?, inKeyWindow: Bool, view: UUID) {}

    /// A message without files.
    func send(_ text: String, to id: ChatConversation.ID?, project: Project, origin: ToolKind?, attachments: [ChatReference],
              reader: ToolReader) async throws(ChatSendError) -> ChatConversation.ID {
        try await send(text, to: id, project: project, origin: origin, attachments: attachments, files: [], reader: reader)
    }
}
