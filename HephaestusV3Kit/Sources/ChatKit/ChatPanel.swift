import AZDesign
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

    @Environment(\.toolReader) private var toolReader
    @Environment(\.openRoute) private var openRoute
    /// The file panel of Add Files… is open.
    @State private var choosesFiles = false

    public init(
        project: Project, origin: ToolKind, subject: ChatReference?, model: ChatPanelModel, hide: @escaping () -> Void
    ) {
        self.project = project
        self.origin = origin
        self.subject = subject
        self.model = model
        self.hide = hide
    }

    public var body: some View {
        let attachment = model.attachment(for: subject)
        VStack(spacing: 0) {
            header
            Divider()
            if let conversation = model.conversation {
                TranscriptScrollView(conversation: conversation, activity: model.activity, compact: true, padding: 14,
                                     decide: { approval, allow in model.decide(approval, allow: allow) }, stop: model.stop)
                    .id(conversation.id)
            } else {
                emptyState(attachment)
            }
            if let failure = model.failure {
                ChatFailure(message: failure)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }
            if let questions = model.conversation?.waitingQuestions {
                QuestionsCard(questionSet: questions, compact: true) { label, text in
                    await model.answer(text, to: label, inSet: questions.id)
                }
                .id(questions.id)
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
            MessageComposer(
                text: $model.draft,
                prompt: Text("Ask about \(attachment?.title ?? project.name)…", bundle: #bundle, comment: "The composer's prompt: an item or a project"),
                isBusy: model.isResponding,
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
                }
            }
            .padding(12)
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.panel")
    }

    private var header: some View {
        HStack(spacing: 10) {
            Label(String(localized: "Chat", bundle: #bundle), systemImage: ToolKind.chat.symbol)
                .font(.headline)
                .foregroundStyle(.textPrimary)
                .accessibilityAddTraits(.isHeader)
            if let conversation = model.conversation {
                Text(verbatim: conversation.title)
                    .font(.callout)
                    .foregroundStyle(.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityIdentifier("chat.panel.title")
            }
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
    /// The message being written.
    var draft = ""
    /// The files going with the next message.
    var files: [URL] = []
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
            if draft == text { draft = "" }
            files.removeAll { sent.contains($0) }
            ChatFiles.clean(sent)
        }
    }

    /// Sends `text`, with the attachment, to the open conversation; the first message starts one, with
    /// the window's project and its tool as the origin. The draft stays as it is.
    @discardableResult
    func send(_ text: String, files: [URL] = [], project: Project, origin: ToolKind, subject: ChatReference?, reader: ToolReader) async -> Bool {
        let attachments = attachment(for: subject).map { [$0] } ?? []
        do throws(ChatSendError) {
            conversationID = try await store.send(text, to: conversationID, project: project, origin: origin, attachments: attachments,
                                                  files: files, reader: reader)
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
        guard let pasted = ChatFiles.pasted() else { return false }
        addFiles(pasted)
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

    /// The user's answer to a change Claude asked to make in the open conversation.
    func decide(_ approvalID: ChatApproval.ID, allow: Bool) {
        guard let conversationID else { return }
        store.decide(approvalID, in: conversationID, allow: allow)
    }

    /// Leaves the conversation for a new one, with an empty draft and the subject attached.
    func startNewChat() {
        conversationID = nil
        draft = ""
        files = []
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
