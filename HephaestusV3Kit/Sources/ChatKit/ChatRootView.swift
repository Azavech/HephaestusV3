import AZDesign
import ChatData
import SwiftUI
import ToolsFoundation

/// The Chat window of a project: its conversations, those started beside a tool included, one of
/// them, and an inspector with what the chat touched and what Claude may do.
///
/// Claude is one more client of the tools here: it reads items through their tools, each read shows as
/// a row that opens the item in its own window, and it asks before it changes anything.
/// What a tab keeps of Chat while another tab is in front: its model, so that its selection, filters
/// and drafts are still there when the tab comes back. The app's window makes one per tab and project.
@MainActor
public final class ChatTabState {
    let model: ChatWindowModel

    public init(project: Project, focus: String? = nil, store: LiveChatStore, directory: ProjectDirectory) {
        model = ChatWindowModel(project: project, focus: focus, store: store, directory: directory)
    }
}

public struct ChatRootView: View {
    @State private var model: ChatWindowModel
    @State private var showsInspector = true
    /// The file panel of Add Files… is open.
    @State private var choosesFiles = false
    /// In an iPhone's layout, the inspector shows as a sheet.
    @State private var showsInspectorSheet = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    @Environment(\.toolReader) private var toolReader
    @Environment(\.windowLayout) private var layout

    /// The chats of `project`, with `focus` (a conversation id) selected, or the latest one. A later
    /// route's focus arrives as a focus request, which selects it without starting afresh.
    public init(project: Project, focus: String? = nil, store: LiveChatStore, directory: ProjectDirectory) {
        _model = State(initialValue: ChatWindowModel(project: project, focus: focus, store: store, directory: directory))
    }

    /// The chats a tab keeps.
    public init(state: ChatTabState) {
        _model = State(initialValue: state.model)
    }

    /// The window on the samples, for previews, with `files` waiting to go with the next message and Find
    /// looking for `findQuery`.
    init(project: Project, focus: String? = nil, samples: SampleChatStore, files: [URL] = [], findQuery: String = "") {
        let model = ChatWindowModel(project: project, focus: focus, store: samples)
        model.files = files
        model.findQuery = findQuery
        model.isFinding = !findQuery.isEmpty
        _model = State(initialValue: model)
    }

    public var body: some View {
        Group {
            if layout == .phone {
                phoneBody
            } else {
                splitBody
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(String(localized: "New Chat", bundle: #bundle), systemImage: "square.and.pencil") {
                    // An iPhone's opens the new chat as a page; the others show it in place.
                    model.startNewChat(asPage: layout == .phone)
                }
                .help(String(localized: "New Chat (⇧⌘N)", bundle: #bundle))
                .accessibilityIdentifier("chat.new")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if layout == .phone {
                        showsInspectorSheet = true
                    } else {
                        showsInspector.toggle()
                    }
                } label: {
                    Label(String(localized: "Inspector", bundle: #bundle), systemImage: "sidebar.right")
                }
                .help(
                    showsInspector
                        ? String(localized: "Hide Inspector", bundle: #bundle)
                        : String(localized: "Show Inspector", bundle: #bundle)
                )
                .accessibilityIdentifier("chat.inspectorToggle")
            }
        }
        .sheet(isPresented: $showsInspectorSheet) {
            VStack(spacing: 0) {
                inspector
                HStack {
                    Spacer()
                    Button(String(localized: "Done", bundle: #bundle, comment: "Closes the inspector sheet")) {
                        showsInspectorSheet = false
                    }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("chat.inspector.done")
                }
                .padding(12)
            }
            .frame(minWidth: 360, minHeight: 480)
        }
        // An iPad's folds the list and the inspector away, behind their buttons.
        .onChange(of: layout, initial: true) {
            columnVisibility = layout == .mac ? .all : .detailOnly
            showsInspector = layout == .mac
        }
        // An iPad's shows one side column at a time, so the conversation keeps its room: opening the
        // inspector folds the list, and showing the list closes the inspector.
        .onChange(of: showsInspector) { _, shown in
            if shown, layout == .pad {
                columnVisibility = .detailOnly
            }
        }
        .onChange(of: columnVisibility) { _, visibility in
            if visibility != .detailOnly, layout == .pad {
                showsInspector = false
            }
        }
        .onFocusRequest { focus in
            model.select(focus: focus)
        }
        // File ▸ New Chat (⇧⌘N), as the toolbar's New Chat.
        .newItemCommand(String(localized: "New Chat", bundle: #bundle, comment: "File menu item, ⇧⌘N")) {
            model.startNewChat(asPage: layout == .phone)
        }
    }

    /// The Mac's list, chat and inspector side by side; an iPad's chat, the others behind their buttons.
    private var splitBody: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            list
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            detail
                .inspector(isPresented: $showsInspector) {
                    inspector
                        .inspectorColumnWidth(min: 260, ideal: 300, max: 400)
                }
        }
    }

    /// An iPhone's: the list of chats, then one as a page with Back.
    private var phoneBody: some View {
        PhoneStack(selection: $model.selection, opensSelection: model.opensSelection) {
            list
        } page: { _ in
            detail
        }
    }

    private var list: some View {
        ChatList(sections: model.sections, isGrouped: model.isGrouped, isEmpty: model.hasNoConversations, selection: $model.selection)
    }

    private var inspector: some View {
        ChatInspector(references: model.references, models: model.store.models, settings: model.replySettings) { settings in
            model.setReplySettings(settings)
        }
    }

    /// The conversation picked, or a new one, over the field to write in.
    private var detail: some View {
        VStack(spacing: 0) {
            if let conversation = model.conversation {
                let matches = ChatFind.matches(of: model.findQuery, in: conversation)
                if !model.findQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                    FindBar(count: matches.count, index: model.findIndex, previous: { model.findIndex -= 1 }, next: { model.findIndex += 1 })
                }
                TranscriptScrollView(conversation: conversation, activity: model.activity, padding: layout == .phone ? 16 : 24,
                                     decide: { approval, allow in model.decide(approval, allow: allow) }, stop: model.stop,
                                     findQuery: model.findQuery,
                                     currentMatch: matches.isEmpty ? nil : matches[((model.findIndex % matches.count) + matches.count) % matches.count])
                    .id(conversation.id)
            } else {
                NewChatPrompt(projectName: model.project.name, suggestions: model.suggestions) { suggestion in
                    Task { await model.send(suggestion, reader: toolReader) }
                }
            }
            if let failure = model.failure {
                ChatFailure(message: failure)
                    .padding(.horizontal, layout == .phone ? 12 : 16)
                    .padding(.top, 8)
            }
            if let questions = model.conversation?.waitingQuestions {
                QuestionsCard(questionSet: questions, compact: layout == .phone) { label, text in
                    await model.answer(text, to: label, inSet: questions.id)
                }
                .id(questions.id)
                .padding(.horizontal, layout == .phone ? 12 : 16)
                .padding(.top, 8)
            }
            MessageComposer(
                text: $model.draft,
                prompt: Text("Ask about \(model.project.name)…", bundle: #bundle, comment: "The composer's prompt: an item or a project"),
                isBusy: model.isResponding,
                identifier: "chat.composer",
                completions: ChatCompletions.list(for: model.draft, commands: model.store.commands(for: model.project.id)),
                hasAttachments: !model.files.isEmpty,
                pastesFiles: { model.pasteFiles() },
                send: { Task { await model.sendDraft(reader: toolReader) } }
            ) {
                FlowStack(spacing: 6) {
                    AddFilesButton { choosesFiles = true }
                    ProjectChip(project: model.project)
                    ForEach(model.files, id: \.self) { url in
                        PendingFileChip(url: url) { model.removeFile(url) }
                    }
                }
            }
            .padding(layout == .phone ? 12 : 16)
        }
        .background(.canvas)
        .searchable(text: $model.findQuery, isPresented: $model.isFinding, placement: .toolbar,
                    prompt: Text("Find in Conversation", bundle: #bundle))
        .onSubmit(of: .search) { model.findIndex += 1 }
        .onChange(of: model.findQuery) { model.findIndex = 0 }
        .fileImporter(isPresented: $choosesFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.addFiles(urls) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.addFiles(urls)
            return true
        }
        .task(id: model.selection) {
            await model.openSelection()
        }
    }
}

/// The project's conversations, and its sub projects' grouped by project, the latest first.
private struct ChatList: View {
    let sections: [ChatWindowModel.Section]
    let isGrouped: Bool
    let isEmpty: Bool
    @Binding var selection: ChatConversation.ID?

    var body: some View {
        List(selection: $selection) {
            ForEach(sections) { section in
                if isGrouped {
                    Section {
                        rows(section.conversations)
                    } header: {
                        Label {
                            Text(verbatim: section.project.name)
                        } icon: {
                            ProjectIcon(section.project)
                        }
                        .accessibilityAddTraits(.isHeader)
                    }
                } else {
                    rows(section.conversations)
                }
            }
        }
        .overlay {
            if isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "No Chats", bundle: #bundle), systemImage: ToolKind.chat.symbol)
                } description: {
                    Text("Ask a question to start one.", bundle: #bundle)
                }
                .accessibilityIdentifier("chat.list.empty")
            }
        }
        .accessibilityIdentifier("chat.list")
    }

    private func rows(_ conversations: [ChatConversation]) -> some View {
        ForEach(conversations) { conversation in
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: conversation.title)
                    .lineLimit(1)
                Group {
                    if let origin = conversation.origin {
                        Text("\(conversation.updatedAt, format: Self.dateFormat) · from \(origin.title)", bundle: #bundle, comment: "A chat's last date, then the tool whose panel started it")
                    } else {
                        Text(conversation.updatedAt, format: Self.dateFormat)
                    }
                }
                .font(.caption)
                .foregroundStyle(.textSecondary)
            }
            .tag(conversation.id)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("chat.list.row.\(conversation.id)")
        }
    }

    /// Day, abbreviated month, hour and minute.
    private static let dateFormat = Date.FormatStyle.dateTime.day().month(.abbreviated).hour().minute()
}

/// A new chat: what it is about, and questions to start from. Centered, and it scrolls when the
/// largest text sizes need more room than the window has.
private struct NewChatPrompt: View {
    let projectName: String
    let suggestions: [String]
    let send: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: ToolKind.chat.symbol)
                    .font(.largeTitle)
                    .foregroundStyle(.accent)
                    .accessibilityHidden(true)
                Text("Ask about \(projectName)", bundle: #bundle, comment: "The empty state's title: an item or a project")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.textPrimary)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text("Claude reads through the tools, and asks before it changes anything. Name a ticket, a run or a request to point at it.", bundle: #bundle)
                    .foregroundStyle(.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                SuggestionList(suggestions: suggestions, pick: send)
            }
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.center, for: .alignment)
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.newChat")
    }
}

/// What the chat touched, what Claude may do, and what answers.
private struct ChatInspector: View {
    let references: [ChatReference]
    /// The models Claude can answer with; empty for the samples.
    let models: [ClaudeModel]
    /// The conversation's model and effort, or those of new chats; nil for the samples.
    let settings: ChatSettings?
    let setSettings: (ChatSettings) -> Void

    @AppStorage(ChatPreferences.ticketChangesKey) private var ticketChanges = ChangePermission.askFirst
    @AppStorage(ChatPreferences.projectChangesKey) private var projectChanges = ChangePermission.askFirst
    @AppStorage(ChatPreferences.buildStartsKey) private var buildStarts = ChangePermission.never
    @Environment(\.openRoute) private var openRoute

    var body: some View {
        Form {
            Section {
                if references.isEmpty {
                    Text("Items Claude reads or you attach show here.", bundle: #bundle)
                        .foregroundStyle(.textSecondary)
                        .accessibilityIdentifier("chat.inspector.empty")
                }
                ForEach(references) { reference in
                    row(reference)
                }
            } header: {
                Text("In This Chat", bundle: #bundle, comment: "A section: the items this chat attached or read")
                    .accessibilityAddTraits(.isHeader)
            }
            ChatPermissionsSection(ticketChanges: $ticketChanges, projectChanges: $projectChanges, buildStarts: $buildStarts,
                                   identifier: "chat.inspector.permissions")
            Section {
                if let settings {
                    ReplySettingsRows(models: models, settings: settings, identifier: "chat.inspector", set: setSettings)
                } else {
                    ModelRow(identifier: "chat.inspector.model")
                    Text("Replies are samples until a model is connected.", bundle: #bundle)
                        .font(.caption)
                        .foregroundStyle(.textSecondary)
                }
            } header: {
                Text("Replies", bundle: #bundle, comment: "A section: what answers the user's messages")
                    .accessibilityAddTraits(.isHeader)
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ reference: ChatReference) -> some View {
        HStack {
            Image(systemName: reference.tool.symbol)
                .foregroundStyle(.accent)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: reference.title)
                Text(reference.tool.title)
                    .font(.caption)
                    .foregroundStyle(.textSecondary)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            Button(String(localized: "Open", bundle: #bundle, comment: "Opens an item in its tool's window")) {
                openRoute(reference.route)
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Open \(reference.title) in \(reference.tool.title)", bundle: #bundle, comment: "An item, then its tool: Open ORD-142 in Tickets"))
            .accessibilityIdentifier("chat.inspector.reference.\(reference.id).open")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.inspector.reference.\(reference.id)")
    }
}

// MARK: - Previews

#Preview("Chat", traits: .appChrome, .fixedLayout(width: 1240, height: 800)) {
    ChatRootView(project: Project.samples[0], samples: .transient())
}

#Preview("Chat, Dark", traits: .appChrome, .fixedLayout(width: 1240, height: 800)) {
    ChatRootView(project: Project.samples[0], samples: .transient())
        .preferredColorScheme(.dark)
}

#Preview("New Chat", traits: .appChrome, .fixedLayout(width: 1000, height: 680)) {
    ChatRootView(project: Project.samples[3], samples: .transient())
}

#Preview("Grouped", traits: .appChrome, .fixedLayout(width: 1240, height: 800)) {
    // Shop, whose sub projects have chats of their own.
    ChatRootView(project: Project.tree.project("SHOP") ?? Project.samples[0], samples: .transient())
}

#Preview("Reading", traits: .appChrome, .fixedLayout(width: 1240, height: 800)) {
    // An engine that takes its time, so the reply stays on its way.
    let store = SampleChatStore(engine: SampleChatEngine(delay: .seconds(3_600)))
    let _ = try? store.send(
        "Is run 1288 enough to close ORD-142?", to: "chat-checkout", project: Project.samples[0], origin: nil,
        attachments: [], files: [], reader: ToolReader { _ in nil }
    )
    ChatRootView(project: Project.samples[0], focus: "chat-checkout", samples: store)
}

#Preview("Approval Answered", traits: .appChrome, .fixedLayout(width: 1240, height: 800)) {
    let store = SampleChatStore.transient()
    let _ = store.decide("chat-checkout.comment", in: "chat-checkout", allow: false)
    ChatRootView(project: Project.samples[0], focus: "chat-checkout", samples: store)
}

#Preview("iPad", traits: .padLayout, .fixedLayout(width: 820, height: 800)) {
    ChatRootView(project: Project.samples[0], samples: .transient())
}

#Preview("iPhone", traits: .phoneLayout, .fixedLayout(width: 420, height: 800)) {
    ChatRootView(project: Project.samples[0], samples: .transient())
}

#Preview("iPhone, Conversation", traits: .phoneLayout, .fixedLayout(width: 420, height: 800)) {
    ChatRootView(project: Project.samples[0], focus: "chat-checkout", samples: .transient())
}

#Preview("iPhone, Dark", traits: .phoneLayout, .fixedLayout(width: 420, height: 800)) {
    ChatRootView(project: Project.samples[0], focus: "chat-checkout", samples: .transient())
        .preferredColorScheme(.dark)
}

#Preview("Largest Text", traits: .largestText, .fixedLayout(width: 1240, height: 800)) {
    ChatRootView(project: Project.samples[0], samples: .transient())
}

#Preview("New Chat, Largest Text", traits: .largestText, .fixedLayout(width: 1000, height: 680)) {
    ChatRootView(project: Project.samples[3], samples: .transient())
}

#Preview("Composer, Files", traits: .appChrome, .fixedLayout(width: 1100, height: 720)) {
    ChatRootView(project: Project.samples[0], focus: "chat-checkout", samples: .transient(),
                 files: [URL(fileURLWithPath: "/System/Library/CoreServices/SystemVersion.plist")])
}

/// Find's count over the transcript, with the previous and next matches: "2 of 5", or "No Matches".
private struct FindBar: View {
    let count: Int
    let index: Int
    let previous: () -> Void
    let next: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Spacer()
            if count == 0 {
                Text("No Matches", bundle: #bundle, comment: "Find found nothing in the conversation")
            } else {
                Text("\(((index % count) + count) % count + 1) of \(count)", bundle: #bundle, comment: "Find's place among its matches: 2 of 5")
                    .monospacedDigit()
            }
            Button(String(localized: "Previous Match", bundle: #bundle), systemImage: "chevron.up", action: previous)
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(count == 0)
                .accessibilityIdentifier("chat.find.previous")
            Button(String(localized: "Next Match", bundle: #bundle), systemImage: "chevron.down", action: next)
                .keyboardShortcut("g", modifiers: .command)
                .disabled(count == 0)
                .accessibilityIdentifier("chat.find.next")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .font(.callout)
        .foregroundStyle(.textSecondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.surfaceSunken)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.find")
    }
}
