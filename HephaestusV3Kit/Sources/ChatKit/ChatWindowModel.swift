import AppKit
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
    /// The conversations selected in the list: one shows beside it; several show their number and Close.
    var selectedIDs: Set<ChatConversation.ID> = []
    /// The conversation shown, the selection's only one; nil for a new chat or several. In an iPhone's layout,
    /// `newChatID` opens a new chat as a page.
    var selection: ChatConversation.ID? {
        get { selectedIDs.count == 1 ? selectedIDs.first : nil }
        set { selectedIDs = newValue.map { [$0] } ?? [] }
    }
    /// Closed chats aren't listed, as V2's filter hid them by default.
    var hidesClosed = true
    /// The chat being renamed, and the title typed.
    var renaming: ChatConversation.ID?
    var newTitle = ""
    /// The chats waiting for the user's yes to Close or Delete….
    var confirming: Confirmation?

    /// A question the window asks before it closes or deletes chats.
    enum Confirmation: Identifiable, Hashable {
        case close([ChatConversation.ID])
        case delete(ChatConversation.ID)

        var id: Self { self }
    }
    /// The message being written. It stays when the user picks another conversation.
    var draft = ""
    /// The files going with the next message.
    var files: [URL] = []
    /// What Find looks for in the shown conversation; empty for nothing.
    var findQuery = ""
    /// The find field shows (⌘F).
    var isFinding = false
    /// The match Find shows, counted from the first and wrapping either way.
    var findIndex = 0
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
            let conversations = store.conversations(of: [member.id]).filter { !hidesClosed || !$0.closed || selectedIDs.contains($0.id) }
            return conversations.isEmpty ? nil : Section(project: member, conversations: conversations)
        }
    }

    /// Whether the filter hides every chat there is.
    var hidesEveryChat: Bool {
        sections.isEmpty && !hasNoConversations
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

    /// The pinned card's answer.
    func decide(_ approvalID: ChatApproval.ID, answer: ChatApproval.Answer) {
        guard let selection else { return }
        store.decide(approvalID, in: selection, answer: answer)
    }

    // MARK: Managing chats

    /// The chats a list action acts on: the selection when it holds `id`, else `id` alone.
    func targets(of id: ChatConversation.ID) -> [ChatConversation.ID] {
        selectedIDs.contains(id) ? Array(selectedIDs) : [id]
    }

    func conversationSummary(_ id: ChatConversation.ID) -> ChatConversation? {
        store.conversations(of: Set(family.map(\.id))).first { $0.id == id }
    }

    func startRenaming(_ id: ChatConversation.ID) {
        newTitle = conversationSummary(id)?.title ?? ""
        renaming = id
    }

    func commitRename() {
        guard let id = renaming else { return }
        renaming = nil
        do throws(ChatSendError) {
            try store.rename(id, to: newTitle)
            failure = nil
        } catch {
            failure = error.message
        }
    }

    /// Closes the chats once the user said yes; the first that fails stops the others.
    func close(_ ids: [ChatConversation.ID]) {
        for id in ids where conversationSummary(id)?.closed == false {
            do throws(ChatSendError) {
                try store.close(id)
            } catch {
                failure = error.message
                return
            }
        }
        failure = nil
    }

    func reopen(_ id: ChatConversation.ID) {
        do throws(ChatSendError) {
            try store.reopen(id)
            failure = nil
        } catch {
            failure = error.message
        }
    }

    func delete(_ id: ChatConversation.ID) {
        do throws(ChatSendError) {
            try store.delete(id)
            selectedIDs.remove(id)
            failure = nil
        } catch {
            failure = error.message
        }
    }

    func resume() async {
        guard let selection, selection != Self.newChatID else { return }
        do throws(ChatSendError) {
            try await store.resume(selection)
            failure = nil
        } catch {
            failure = error.message
        }
    }

    /// The shown conversation as plain text, for Copy Conversation.
    func copyConversation(_ id: ChatConversation.ID) async {
        await store.open(id)
        guard let conversation = store.conversation(id) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(conversation.plainText, forType: .string)
    }

    /// Leaves the conversation for a new chat, with an empty draft: in place, or as a page.
    func startNewChat(asPage: Bool) {
        selection = asPage ? Self.newChatID : nil
        draft = ""
    }

    /// Sends the draft and its files, and clears them once sent.
    func sendDraft(reader: ToolReader) async {
        let text = draft
        let sent = files
        if await send(text, files: sent, reader: reader) {
            if draft == text { draft = "" }
            files.removeAll { sent.contains($0) }
            ChatFiles.clean(sent)
        }
    }

    /// Sends `text` and `files` to the shown conversation, or starts one about the project, and shows it.
    /// Messages from the Chat window carry the project, not an item. The draft stays.
    @discardableResult
    func send(_ text: String, files: [URL] = [], reader: ToolReader) async -> Bool {
        let target = selection == Self.newChatID ? nil : selection
        do throws(ChatSendError) {
            let id = try await store.send(text, to: target, project: project, origin: nil, attachments: [], files: files, reader: reader)
            failure = nil
            selection = id
            return true
        } catch {
            failure = error.message.isEmpty ? nil : error.message
            return false
        }
    }

    // MARK: Files

    /// Adds files to the next message; a folder, or files over the limits, are refused with the reason shown.
    func addFiles(_ urls: [URL]) {
        let result = ChatFiles.adding(urls, to: files)
        files = result.files
        failure = result.failure
    }

    func removeFile(_ url: URL) {
        files.removeAll { $0 == url }
    }

    /// ⌘V in the composer: the pasteboard's files, or its image, go with the next message; false lets the field
    /// paste its text.
    func pasteFiles() -> Bool {
        guard let pasted = ChatFiles.pasted() else { return false }
        addFiles(pasted)
        return true
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
