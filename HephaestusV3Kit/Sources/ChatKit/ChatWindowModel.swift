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
    private let store: ChatStore
    /// The conversation shown; nil for a new chat. In an iPhone's layout, `newChatID` opens a new chat
    /// as a page.
    var selection: ChatConversation.ID?
    /// The message being written. It stays when the user picks another conversation.
    var draft = ""
    /// Opened on a conversation: an iPhone's layout starts on its page.
    let opensSelection: Bool

    /// In an iPhone's layout, the page of a new chat, before it has an id of its own.
    static let newChatID = "chat-new"

    /// The chats of `project` and its sub projects, with `focus` (a conversation id) selected, or the
    /// latest one when the focus names none of them.
    init(project: Project, focus: String?, store: ChatStore) {
        self.project = project
        self.store = store
        let family = Set(Project.tree.family(of: project.id).map(\.id))
        let conversations = store.conversations(of: family)
        let focused = conversations.first { $0.id == focus }
        opensSelection = focused != nil
        selection = focused?.id ?? conversations.first?.id
    }

    /// The project and its sub projects, in tree order.
    var family: [Project] {
        Project.tree.family(of: project.id)
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

    /// Whether the shown conversation waits for a reply, which disables Send.
    var isResponding: Bool {
        store.isResponding(selection)
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

    /// Sends the draft and clears it.
    func sendDraft(reader: ToolReader) {
        if send(draft, reader: reader) {
            draft = ""
        }
    }

    /// Sends `text` to the shown conversation, or starts one about the project, and shows it. Messages
    /// from the Chat window carry no attachments: the items they name are read instead. The draft stays.
    @discardableResult
    func send(_ text: String, reader: ToolReader) -> Bool {
        let target = selection == Self.newChatID ? nil : selection
        guard let id = store.send(text, to: target, project: project, origin: nil, attachments: [], reader: reader) else {
            return false
        }
        selection = id
        return true
    }

    /// The user's answer to a change Claude asked to make in the shown conversation.
    func decide(_ approvalID: ChatApproval.ID, allow: Bool) {
        guard let selection else { return }
        store.decide(approvalID, in: selection, allow: allow)
    }
}
