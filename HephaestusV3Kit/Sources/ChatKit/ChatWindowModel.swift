import ChatData
import Foundation
import Observation
import ToolsFoundation

/// The Chat window of a project: which conversations it lists, which one it shows, what a route's
/// focus selects, the draft, and what its buttons do.
@Observable
final class ChatWindowModel {
    /// The conversations of one project of the family, for a section of the list.
    struct Section: Identifiable {
        let project: Project
        let conversations: [ChatConversation]

        var id: Project.ID { project.id }
    }

    let project: Project
    let store: any ChatStore
    private let directory: ProjectDirectory
    /// The conversation shown; nil for a new chat. In an iPhone's layout, `newChatID` opens a new chat
    /// as a page.
    var selection: ChatConversation.ID?
    /// The message being written. It stays when the user picks another conversation.
    var draft = ""
    /// Opened on a conversation: an iPhone's layout starts on its page.
    let opensSelection: Bool
    /// Why the last message wasn't sent; the next message clears it.
    var failure: String?

    /// In an iPhone's layout, the page of a new chat, before it has an id of its own.
    static let newChatID = "chat-new"

    /// The chats of `project` and its sub projects, with `focus` (a conversation id) selected, or the
    /// latest one when the focus names none of them.
    init(project: Project, focus: String?, store: any ChatStore, directory: ProjectDirectory = .previewSamples) {
        self.project = project
        self.store = store
        self.directory = directory
        let family = Set(directory.tree.family(of: project.id).map(\.id))
        let conversations = store.conversations(of: family)
        let focused = conversations.first { $0.id == focus }
        opensSelection = focused != nil
        selection = focused?.id ?? conversations.first?.id
    }

    /// The project and its sub projects, in tree order.
    var family: [Project] {
        directory.tree.family(of: project.id)
    }

    /// Whether the list groups its conversations by project: only for a project with sub projects.
    var isGrouped: Bool {
        family.count > 1
    }

    /// One section per project of the family that has conversations, in tree order; each the latest
    /// first.
    var sections: [Section] {
        family.compactMap { member in
            let conversations = store.conversations(of: [member.id])
            return conversations.isEmpty ? nil : Section(project: member, conversations: conversations)
        }
    }

    /// Whether neither the project nor its sub projects have a conversation.
    var hasNoConversations: Bool {
        store.conversations(of: Set(family.map(\.id))).isEmpty
    }

    var conversation: ChatConversation? {
        store.conversation(selection)
    }

    /// What Claude is doing in the shown conversation; nil when nothing.
    var activity: ChatActivity? {
        store.activity(selection)
    }

    /// Whether the shown conversation waits for a reply, which disables Send.
    var isResponding: Bool {
        activity != nil
    }

    /// Stops Claude in the shown conversation; nil where nothing can be stopped.
    var stop: (() -> Void)? {
        guard store.canStop, let selection, selection != Self.newChatID else { return nil }
        return { [store] in store.stop(selection) }
    }

    /// Reads the shown conversation's turns.
    func openSelection() async {
        guard let selection, selection != Self.newChatID else { return }
        await store.open(selection)
    }

    /// What the shown conversation attached or read, for the inspector.
    var references: [ChatReference] {
        conversation?.references ?? []
    }

    /// What the new-chat prompt offers to ask.
    var suggestions: [String] {
        ChatSuggestion.project
    }

    /// Selects the conversation a route asks for, when the list has it.
    func select(focus: String) {
        guard sections.contains(where: { $0.conversations.contains { $0.id == focus } }) else { return }
        selection = focus
    }

    /// Leaves the conversation for a new chat, with an empty draft: in place, or as a page.
    func startNewChat(asPage: Bool) {
        selection = asPage ? Self.newChatID : nil
        draft = ""
    }

    /// Sends the draft and clears it, once sent.
    func sendDraft(reader: ToolReader) async {
        let text = draft
        if await send(text, reader: reader), draft == text {
            draft = ""
        }
    }

    /// Sends `text` to the shown conversation, or starts one about the project, and shows it. Messages
    /// from the Chat window carry the project, not an item. The draft stays.
    @discardableResult
    func send(_ text: String, reader: ToolReader) async -> Bool {
        let target = selection == Self.newChatID ? nil : selection
        do throws(ChatSendError) {
            let id = try await store.send(text, to: target, project: project, origin: nil, attachments: [], reader: reader)
            failure = nil
            selection = id
            return true
        } catch {
            failure = error.message.isEmpty ? nil : error.message
            return false
        }
    }

    /// The user's answer to one of Claude's questions; false, with the reason shown, when it wasn't taken.
    func answer(_ answer: String, to label: String, inSet setID: ChatQuestionSet.ID) async -> Bool {
        guard let id = selection else { return false }
        do throws(ChatSendError) {
            try await store.answer(answer, to: label, inSet: setID, of: id)
            failure = nil
            return true
        } catch {
            failure = error.message
            return false
        }
    }

    /// The user's answer to a change Claude asked to make in the shown conversation.
    func decide(_ approvalID: ChatApproval.ID, allow: Bool) {
        guard let selection else { return }
        store.decide(approvalID, in: selection, allow: allow)
    }

    // MARK: Replies

    /// The shown conversation's model and effort, or those of new chats; nil without a model (the samples).
    var replySettings: ChatSettings? {
        store.replySettings(of: selection == Self.newChatID ? nil : selection)
    }

    func setReplySettings(_ settings: ChatSettings) {
        do throws(ChatSendError) {
            try store.setReplySettings(settings, of: selection == Self.newChatID ? nil : selection)
        } catch {
            failure = error.message
        }
    }
}
