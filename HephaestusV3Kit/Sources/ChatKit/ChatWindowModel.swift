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
    /// The new chat's draft; an existing chat's is the store's, shared by every view of it.
    private var composer = ComposerDraft()
    /// The chat whose draft the composer shows: the selection, or nil for a new chat.
    private var draftID: ChatConversation.ID? {
        selection == Self.newChatID ? nil : selection
    }
    /// The message being written: the shown chat's, as V2 kept one per chat.
    var draft: String {
        get { composer.text(of: draftID, in: store.drafts) }
        set {
            guard newValue != draft else { return }
            composer.setText(newValue, of: draftID, in: store.drafts)
        }
    }
    /// The files going with the next message.
    var files: [URL] {
        get { composer.files(of: draftID, in: store.drafts) }
        set {
            guard newValue != files else { return }
            composer.setFiles(newValue, of: draftID, in: store.drafts)
        }
    }
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
        // A tab restored at launch is made before the chats are read: it selects once they come.
        if conversations.isEmpty { pendingFocus = focus ?? "" }
    }

    /// The focus a model made before the chats were read waits with: "" for the latest chat; nil once used.
    private var pendingFocus: String?

    /// The chats came after the model was made: the focus, else the latest chat, is selected, unless the user
    /// picked a chat or started one meanwhile.
    func chatsArrived() {
        guard let focus = pendingFocus, !hasNoConversations else { return }
        pendingFocus = nil
        guard selection == nil, draft.isEmpty, files.isEmpty else { return }
        let conversations = store.conversations(of: Set(family.map(\.id)))
        selection = (conversations.first { $0.id == focus } ?? conversations.first)?.id
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

    /// The agent or workflow row selected in the list, under its chat; nil for a chat.
    var selectedAgent: ChatAgentRow? {
        guard let selection, let tag = ChatAgentRow.parse(selection) else { return nil }
        return store.agentRows(of: tag.chatID).first { $0.id == tag.id && ($0.kind == .workflow) == tag.isWorkflow }
    }

    /// Selects an agent's row, from its workflow's view.
    func select(_ row: ChatAgentRow) {
        selection = row.tag
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

    /// Selects the conversation a route asks for, when the project or a sub project has it: a closed one too,
    /// which the list then shows while it is selected, as a new window would select it.
    func select(focus: String) {
        guard conversationSummary(focus) != nil else { return }
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
        composer = ComposerDraft()
    }

    /// Sends the draft and its files, and clears them once sent.
    func sendDraft(reader: ToolReader) async {
        let text = draft
        let sent = files
        if await send(text, files: sent, reader: reader) {
            // A new chat's draft became the chat's as it got its id.
            composer.clear(sentText: text, sentFiles: sent, from: draftID, in: store.drafts)
            ChatFiles.clean(sent)
        }
    }

    /// Sends `text` and `files` to the shown conversation, or starts one about the project, and shows it.
    /// Messages from the Chat window carry the project, not an item. The draft stays.
    @discardableResult
    func send(_ text: String, files: [URL] = [], reader: ToolReader) async -> Bool {
        // A chat deleted elsewhere while shown: the message starts a new chat instead of failing.
        let target = (selection == Self.newChatID ? nil : selection).flatMap { store.conversation($0) != nil ? $0 : nil }
        do throws(ChatSendError) {
            let id = try await store.send(text, to: target, project: project, origin: nil, attachments: [], files: files, reader: reader)
            failure = nil
            if target == nil { composer.adopt(id, in: store.drafts) }
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
        guard let paste = ChatFiles.take() else { return false }
        switch paste {
        case .files(let urls):
            addFiles(urls)
        case .image(let data):
            // Converted and written off the main actor: the key press is answered at once.
            let now = Date()
            Task {
                if let file = await Task.detached(operation: { ChatFiles.write(image: data, now: now) }).value { addFiles([file]) }
            }
        }
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

    /// The user's answer to Claude's picker request; false, with the reason shown, when it wasn't taken.
    func answerPicker(_ answer: String, request requestID: String) async -> Bool {
        guard let id = selection else { return false }
        do throws(ChatSendError) {
            try await store.answerPicker(answer, request: requestID, of: id)
            failure = nil
            return true
        } catch {
            failure = error.message
            return false
        }
    }

    /// The catalogues of the shown conversation's picker card.
    var pickerCatalogs: PickerCatalogAccess? {
        selection.map(store.pickerCatalogs(of:))
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
