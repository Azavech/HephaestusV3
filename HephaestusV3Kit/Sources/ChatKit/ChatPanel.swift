import AZDesign
import ChatData
import SwiftUI
import ToolsFoundation

/// The chat beside a tool window: a conversation about the item the tool has selected, which the
/// message carries as a chip. Its conversations are the Chat window's too, and one opens there with a
/// click. The window shows or hides the panel; Settings can take it off every window.
public struct ChatPanel: View {
    let project: Project
    /// The tool beside which the panel shows.
    let origin: ToolKind
    /// The item the tool has selected, if any.
    let subject: ChatReference?
    /// The open conversation and the draft, which the window keeps while the panel is hidden.
    @Bindable var model: ChatPanelModel
    let hide: () -> Void
    /// A chat window's chat has no header: the window's title names it.
    var showsHeader = true

    @Environment(\.toolReader) private var toolReader
    @Environment(\.openRoute) private var openRoute
    /// The file panel of Add Files… is open.
    @State private var choosesFiles = false

    public init(
        project: Project, origin: ToolKind, subject: ChatReference?, model: ChatPanelModel, hide: @escaping () -> Void,
        showsHeader: Bool = true
    ) {
        self.project = project
        self.origin = origin
        self.subject = subject
        self.model = model
        self.hide = hide
        self.showsHeader = showsHeader
    }

    /// The conversation is read once: each read asks the store for it. The composer is a view of its own, so that
    /// typing draws it alone.
    public var body: some View {
        let attachment = model.attachment(for: subject)
        let conversation = model.conversation
        let pending = conversation?.pendingApprovals ?? []
        VStack(spacing: 0) {
            if showsHeader {
                header(title: conversation?.title)
                Divider()
            }
            if let conversation {
                TranscriptScrollView(conversation: conversation, activity: model.activity, compact: true, padding: 14,
                                     decide: { approval, allow in model.decide(approval, allow: allow) }, stop: model.stop)
                    .id(conversation.id)
            } else {
                emptyState(attachment)
            }
            OverComposer {
                if let status = model.store.cliStatus, ClaudeCLILine.shows(status), conversation?.closed != true {
                    ClaudeCLILine(status: status)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                }
                if let failure = model.failure, failure != model.store.cliStatus?.error {
                    ChatFailure(message: failure)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                }
                if conversation?.needsResume == true {
                    ResumeLine { Task { await model.resume() } }
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                }
                if !pending.isEmpty {
                    PermissionCard(approvals: pending) { id, answer in model.decide(id, answer: answer) }
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                }
                if let questions = conversation?.waitingQuestions {
                    QuestionsCard(questionSet: questions, projectID: conversation?.projectID, compact: true, allowsShortcut: pending.isEmpty) { label, text in
                        await model.answer(text, to: label, inSet: questions.id)
                    }
                    .id(questions.id)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                }
                if let request = conversation?.waitingPicker, let catalogs = model.pickerCatalogs {
                    PickerCard(request: request, projectID: conversation?.projectID ?? project.id, catalogs: catalogs, compact: true,
                               allowsShortcut: pending.isEmpty) { answer in
                        await model.answerPicker(answer, request: request.requestID)
                    }
                    .id(request.requestID)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                }
            }
            if let conversation, conversation.closed {
                ClosedNotice { model.reopen() }
                    .padding(12)
            } else {
                PanelComposer(project: project, origin: origin, subject: subject, model: model, usage: ComposerUsage(conversation),
                              choosesFiles: $choosesFiles)
            }
        }
        .background(.canvas)
        .fileImporter(isPresented: $choosesFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.addFiles(urls) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.addFiles(urls)
            return true
        }
        .onChange(of: subject) {
            model.subjectChanged()
        }
        .task(id: model.conversationID) {
            await model.openConversation()
        }
        .reportsShownChat(model.conversationID, store: model.store)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.panel")
    }

    /// The panel's header, with the pop-up titled `title`, the conversation's; nil for a new chat.
    private func header(title: String?) -> some View {
        HStack(spacing: 10) {
            Label(String(localized: "Chat", bundle: #bundle), systemImage: ToolKind.chat.symbol)
                .font(.headline)
                .foregroundStyle(.textPrimary)
                .accessibilityAddTraits(.isHeader)
            chatPicker(title: title)
            Spacer(minLength: 4)
            Button(String(localized: "New Chat", bundle: #bundle), systemImage: "square.and.pencil") {
                model.startNewChat()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .disabled(!model.canStartNewChat)
            .help(String(localized: "New Chat", bundle: #bundle))
            .accessibilityIdentifier("chat.panel.new")
            Button(String(localized: "Open in Chat Window", bundle: #bundle), systemImage: "macwindow") {
                openRoute(model.chatWindowRoute(for: project))
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help(String(localized: "Open in the Chat Window", bundle: #bundle))
            .accessibilityIdentifier("chat.panel.openWindow")
            Button(String(localized: "Hide Chat", bundle: #bundle), systemImage: "xmark", action: hide)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(String(localized: "Hide the Chat Panel (⌃⌘C)", bundle: #bundle))
                .accessibilityIdentifier("chat.panel.hide")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// V2's pop-up of the project's chats: the one shown, the others to switch to, the latest first, each with
    /// its mark; then Open in New Window. A closed chat is listed only while it shows, and a ticket's, bundle's, CI or
    /// feedback chat only while it shows too: their items list them, as V2's did.
    private func chatPicker(title: String?) -> some View {
        let chats = model.store.conversations(of: [project.id]).filter {
            (!$0.closed && !$0.isItemChat) || $0.id == model.conversationID
        }
        return Menu {
            Picker(String(localized: "Chats", bundle: #bundle, comment: "The panel's list of the project's chats"),
                   selection: Binding(get: { model.conversationID }, set: { model.show($0) })) {
                ForEach(chats) { chat in
                    Group {
                        if let symbol = Self.symbol(of: chat.mark) {
                            Label(chat.title, systemImage: symbol)
                        } else {
                            Text(verbatim: chat.title)
                        }
                    }
                    .tag(Optional(chat.id))
                    .accessibilityIdentifier("chat.panel.chats.\(chat.id)")
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Button(String(localized: "Open in New Window", bundle: #bundle, comment: "Opens a chat in a window of its own"), systemImage: "macwindow.badge.plus") {
                if let id = model.conversationID { openRoute(.chatWindow(chat: id)) }
            }
            .disabled(model.conversationID == nil)
            .accessibilityIdentifier("chat.panel.openNewWindow")
        } label: {
            Text(verbatim: title ?? String(localized: "New Chat", bundle: #bundle))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .menuStyle(.borderlessButton)
        .font(.callout)
        .foregroundStyle(.textSecondary)
        .disabled(chats.isEmpty && model.conversationID == nil)
        .help(String(localized: "Chats", bundle: #bundle, comment: "The panel's list of the project's chats"))
        .accessibilityIdentifier("chat.panel.chats")
    }

    /// A chat's mark in the pop-up, where a spinner can't turn: V2's `progress.indicator` for work.
    static func symbol(of mark: ChatMark?) -> String? {
        switch mark {
        case .working?: "progress.indicator"
        case .waiting?: "hand.raised"
        case .error?: "exclamationmark.triangle"
        case nil: nil
        }
    }

    /// Before the first message: what the chat is about, how Claude reaches it, and questions to start
    /// from. It scrolls when the largest text sizes need more room than the panel has.
    private func emptyState(_ attachment: ChatReference?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Ask about \(attachment?.title ?? project.name)", bundle: #bundle, comment: "The empty state's title: an item or a project")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Group {
                    if let attachment {
                        Text("Claude reads it through \(attachment.tool.title), and asks before it changes anything.", bundle: #bundle, comment: "The item's tool, such as Tickets")
                    } else {
                        Text("Claude reads through the tools, and asks before it changes anything. Name a ticket, a run or a request to point at it.", bundle: #bundle)
                    }
                }
                .font(.callout)
                .foregroundStyle(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                SuggestionList(suggestions: model.suggestions(for: subject, reader: toolReader)) { suggestion in
                    Task { await model.send(suggestion, project: project, origin: origin, subject: subject, reader: toolReader) }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.panel.empty")
    }
}

/// The panel's composer, with the draft of the chat shown and what the next message carries: a view of its own, which
/// typing draws alone.
private struct PanelComposer: View {
    let project: Project
    let origin: ToolKind
    let subject: ChatReference?
    @Bindable var model: ChatPanelModel
    let usage: ComposerUsage
    @Binding var choosesFiles: Bool

    @Environment(\.toolReader) private var toolReader

    var body: some View {
        let attachment = model.attachment(for: subject)
        MessageComposer(
            text: $model.draft,
            prompt: Text("Ask about \(attachment?.title ?? project.name)…", bundle: #bundle, comment: "The composer's prompt: an item or a project"),
            isBusy: (model.isResponding && !model.store.queuesMessages) || model.store.cliStatus?.checking == true,
            identifier: "chat.composer",
            completions: ChatCompletions.list(for: model.draft, commands: model.store.commands(for: project.id)),
            hasAttachments: !model.files.isEmpty,
            pastesFiles: { model.pasteFiles() },
            send: { Task { await model.sendDraft(project: project, origin: origin, subject: subject, reader: toolReader) } }
        ) {
            FlowStack(spacing: 6) {
                AddFilesButton { choosesFiles = true }
                chip(attachment)
                ForEach(model.files, id: \.self) { url in
                    PendingFileChip(url: url) { model.removeFile(url) }
                }
                if let settings = model.replySettings {
                    // The chat's settings, as V2's composer folded them into one menu.
                    Menu {
                        ReplySettingsRows(models: model.store.models, settings: settings, identifier: "chat.panel.settings",
                                          isChat: model.conversationID != nil) { model.setReplySettings($0) }
                    } label: {
                        Label(String(localized: "Chat Settings", bundle: #bundle), systemImage: "slider.horizontal.3")
                    }
                    .labelStyle(.iconOnly)
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help(String(localized: "Chat Settings", bundle: #bundle))
                    .accessibilityIdentifier("chat.panel.settings")
                    if settings.permissionMode == ChatPermissionMode.bypassPermissions.rawValue, model.conversationID != nil {
                        AllowAllBadge()
                    }
                }
                if let context = usage.context {
                    ContextIndicator(usage: context, compactions: usage.compactions, isCompacting: usage.isCompacting)
                }
            }
        }
        .padding(12)
        .stopsOnEscape(model.isResponding ? model.stop : nil)
    }

    /// What the next message carries: the tool's selection, the button that puts it back once taken
    /// off, or the project when the tool has nothing selected.
    @ViewBuilder private func chip(_ attachment: ChatReference?) -> some View {
        if let attachment {
            ContextChip(reference: attachment, identifier: "chat.composer.attachment") {
                model.leaveOut(attachment)
            }
        } else if let subject {
            Button(String(localized: "Attach \(subject.title)", bundle: #bundle), systemImage: "plus") {
                model.attach()
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .accessibilityIdentifier("chat.composer.attach")
        } else {
            ProjectChip(project: project)
        }
    }
}

/// The chat panel of one window: the open conversation, the draft and the subject the user took off,
/// and what the panel's buttons do. The window holds it, so hiding and showing the panel keeps them
/// until New Chat, or until the window switches to another project, which starts a new model (the
/// user's choice).
@Observable
public final class ChatPanelModel {
    let store: any ChatStore
    /// The conversation the panel shows; nil before the first message, and after New Chat.
    var conversationID: ChatConversation.ID?
    /// The new chat's draft; an existing chat's is the store's, shared by every view of it.
    private var composer = ComposerDraft()
    /// The message being written: the shown chat's.
    var draft: String {
        get { composer.text(of: conversationID, in: store.drafts) }
        set {
            guard newValue != draft else { return }
            composer.setText(newValue, of: conversationID, in: store.drafts)
        }
    }
    /// The files going with the next message.
    var files: [URL] {
        get { composer.files(of: conversationID, in: store.drafts) }
        set {
            guard newValue != files else { return }
            composer.setFiles(newValue, of: conversationID, in: store.drafts)
        }
    }
    /// The subject the user took off the next message; it comes back when the selection changes.
    var leftOut: ChatReference.ID?
    /// Why the last message wasn't sent; the next message clears it.
    var failure: String?

    /// The panel of a window of the app, on its chats.
    public convenience init(store: LiveChatStore) {
        self.init(chats: store)
    }

    init(chats: any ChatStore) {
        self.store = chats
    }

    var conversation: ChatConversation? {
        store.conversation(conversationID)
    }

    /// What Claude is doing in the open conversation; nil when nothing.
    var activity: ChatActivity? {
        store.activity(conversationID)
    }

    /// Whether the open conversation waits for a reply, which disables Send.
    var isResponding: Bool {
        activity != nil
    }

    /// Stops Claude in the open conversation; nil where nothing can be stopped.
    var stop: (() -> Void)? {
        guard store.canStop, let conversationID else { return nil }
        return { [store] in store.stop(conversationID) }
    }

    /// Reads the open conversation's turns.
    func openConversation() async {
        guard let conversationID else { return }
        await store.open(conversationID)
    }

    /// New Chat leaves an open conversation; with none, there is nothing to leave.
    var canStartNewChat: Bool {
        conversationID != nil
    }

    /// The item the next message carries: the tool's selection, unless the user took it off.
    func attachment(for subject: ChatReference?) -> ChatReference? {
        guard let subject, subject.id != leftOut else { return nil }
        return subject
    }

    /// Takes the subject off the next message.
    func leaveOut(_ subject: ChatReference) {
        leftOut = subject.id
    }

    /// Puts the subject the user took off back on the next message.
    func attach() {
        leftOut = nil
    }

    /// A new selection in the tool is attached again, even one the user took off before.
    func subjectChanged() {
        leftOut = nil
    }

    /// What to ask about the attached item, as its tool proposes for its state; about the project when
    /// nothing is attached.
    func suggestions(for subject: ChatReference?, reader: ToolReader) -> [String] {
        attachment(for: subject).map { ChatSuggestion.about($0, reader: reader) } ?? ChatSuggestion.project
    }

    /// Sends the draft, with the attachment and the files, and clears them once sent.
    func sendDraft(project: Project, origin: ToolKind, subject: ChatReference?, reader: ToolReader) async {
        let text = draft
        let sent = files
        if await send(text, files: sent, project: project, origin: origin, subject: subject, reader: reader) {
            // A new chat's draft became the chat's as it got its id.
            composer.clear(sentText: text, sentFiles: sent, from: conversationID, in: store.drafts)
            ChatFiles.clean(sent)
        }
    }

    /// Sends `text`, with the attachment, to the open conversation; the first message starts one, with
    /// the window's project and its tool as the origin. The draft stays as it is.
    @discardableResult
    func send(_ text: String, files: [URL] = [], project: Project, origin: ToolKind, subject: ChatReference?, reader: ToolReader) async -> Bool {
        let attachments = attachment(for: subject).map { [$0] } ?? []
        // A chat deleted elsewhere while shown: the message starts a new chat instead of failing.
        if let id = conversationID, store.conversation(id) == nil { conversationID = nil }
        do throws(ChatSendError) {
            let id = try await store.send(text, to: conversationID, project: project, origin: origin, attachments: attachments,
                                          files: files, reader: reader)
            if conversationID == nil { composer.adopt(id, in: store.drafts) }
            conversationID = id
            failure = nil
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
        guard let id = conversationID else { return false }
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
        guard let id = conversationID else { return false }
        do throws(ChatSendError) {
            try await store.answerPicker(answer, request: requestID, of: id)
            failure = nil
            return true
        } catch {
            failure = error.message
            return false
        }
    }

    /// The catalogues of the open conversation's picker card.
    var pickerCatalogs: PickerCatalogAccess? {
        conversationID.map(store.pickerCatalogs(of:))
    }

    /// The user's answer to a change Claude asked to make in the open conversation.
    func decide(_ approvalID: ChatApproval.ID, allow: Bool) {
        guard let conversationID else { return }
        store.decide(approvalID, in: conversationID, allow: allow)
    }

    /// The open conversation's model and settings, or those of new chats; nil without models (the samples).
    var replySettings: ChatSettings? {
        store.replySettings(of: conversationID)
    }

    func setReplySettings(_ settings: ChatSettings) {
        do throws(ChatSendError) {
            try store.setReplySettings(settings, of: conversationID)
            failure = nil
        } catch {
            failure = error.message
        }
    }

    /// The pinned card's answer.
    func decide(_ approvalID: ChatApproval.ID, answer: ChatApproval.Answer) {
        guard let conversationID else { return }
        store.decide(approvalID, in: conversationID, answer: answer)
    }

    /// Reopens the open conversation, closed.
    func reopen() {
        guard let conversationID else { return }
        do throws(ChatSendError) {
            try store.reopen(conversationID)
            failure = nil
        } catch {
            failure = error.message
        }
    }

    /// Resume: Claude goes on after an error, through the internal skill `resume-chat`.
    func resume() async {
        guard let conversationID else { return }
        do throws(ChatSendError) {
            try await store.resume(conversationID)
            failure = nil
        } catch {
            failure = error.message
        }
    }

    /// Shows another chat of the project, from the pop-up; its own draft comes with it.
    func show(_ id: ChatConversation.ID?) {
        guard let id, id != conversationID else { return }
        conversationID = id
        failure = nil
    }

    /// Leaves the conversation for a new one, with an empty draft and the subject attached.
    func startNewChat() {
        conversationID = nil
        composer = ComposerDraft()
        leftOut = nil
        failure = nil
    }

    /// The project's Chat window, on the open conversation, if any.
    func chatWindowRoute(for project: Project) -> Route {
        .tool(.chat, project: project.id, focus: conversationID)
    }
}

// MARK: - Previews

private let ord142 = ChatReference(tool: .tickets, projectID: "ORD", focus: "ORD-142", title: "ORD-142")

/// A panel model on the samples, with `conversation` open.
private func previewModel(_ store: SampleChatStore = .transient(), open conversation: ChatConversation.ID? = nil) -> ChatPanelModel {
    let model = ChatPanelModel(chats: store)
    model.conversationID = conversation
    return model
}

#Preview("Panel, Ticket", traits: .appChrome, .fixedLayout(width: 341, height: 640)) {
    ChatPanel(project: Project.samples[0], origin: .tickets, subject: ord142, model: previewModel(), hide: {})
}

#Preview("Panel, Checking the CLI", traits: .appChrome, .fixedLayout(width: 341, height: 640)) {
    let store = SampleChatStore.transient()
    let _ = store.cliStatus = .checking
    ChatPanel(project: Project.samples[0], origin: .tickets, subject: ord142, model: ChatPanelModel(chats: store), hide: {})
}

#Preview("Panel, CLI Not Found", traits: .appChrome, .fixedLayout(width: 341, height: 640)) {
    let store = SampleChatStore.transient()
    let _ = store.cliStatus = ClaudeStatus(error: "Claude CLI not found. Install Claude Code, or set its path in Settings ▸ Chat.")
    ChatPanel(project: Project.samples[0], origin: .tickets, subject: ord142, model: ChatPanelModel(chats: store), hide: {})
}

#Preview("Panel, No Subject", traits: .appChrome, .fixedLayout(width: 341, height: 640)) {
    ChatPanel(project: Project.samples[0], origin: .dashboard, subject: nil, model: previewModel(), hide: {})
}

#Preview("Panel, Subject Taken Off", traits: .appChrome, .fixedLayout(width: 341, height: 640)) {
    let model = previewModel()
    let _ = model.leaveOut(ord142)
    ChatPanel(project: Project.samples[0], origin: .tickets, subject: ord142, model: model, hide: {})
}

#Preview("Panel, Conversation", traits: .appChrome, .fixedLayout(width: 341, height: 720)) {
    ChatPanel(project: Project.samples[0], origin: .tickets, subject: ord142, model: previewModel(open: "chat-checkout"), hide: {})
}

#Preview("Panel, Conversation, Dark", traits: .appChrome, .fixedLayout(width: 341, height: 720)) {
    ChatPanel(project: Project.samples[0], origin: .tickets, subject: ord142, model: previewModel(open: "chat-checkout"), hide: {})
        .preferredColorScheme(.dark)
}

#Preview("Panel, Approval Answered", traits: .appChrome, .fixedLayout(width: 341, height: 720)) {
    let store = SampleChatStore.transient()
    let _ = store.decide("chat-checkout.comment", in: "chat-checkout", allow: true)
    ChatPanel(project: Project.samples[0], origin: .tickets, subject: ord142, model: previewModel(store, open: "chat-checkout"), hide: {})
}

#Preview("Panel, Reading", traits: .appChrome, .fixedLayout(width: 341, height: 640)) {
    // An engine that takes its time, so the reply stays on its way.
    let store = SampleChatStore(engine: SampleChatEngine(delay: .seconds(3_600)))
    let id = try? store.send("Is run 1288 enough to close it?", to: nil, project: Project.samples[0], origin: .tickets, attachments: [ord142],
                             files: [], reader: ToolReader { _ in nil })
    let model = previewModel(store, open: id)
    ChatPanel(project: Project.samples[0], origin: .tickets, subject: ord142, model: model, hide: {})
}

#Preview("Panel, iPhone", traits: .phoneLayout, .fixedLayout(width: 420, height: 800)) {
    ChatPanel(project: Project.samples[0], origin: .tickets, subject: ord142, model: previewModel(open: "chat-checkout"), hide: {})
}

#Preview("Panel, Largest Text", traits: .largestText, .fixedLayout(width: 341, height: 720)) {
    ChatPanel(project: Project.samples[0], origin: .tickets, subject: ord142, model: previewModel(), hide: {})
}

#Preview("Panel, Conversation, Largest Text", traits: .largestText, .fixedLayout(width: 341, height: 720)) {
    ChatPanel(project: Project.samples[0], origin: .tickets, subject: ord142, model: previewModel(open: "chat-checkout"), hide: {})
}
