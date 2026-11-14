import AZDesign
import SwiftUI
import ToolsFoundation

/// The Chat window of a project: its conversations, those started beside a tool included, one of
/// them, and an inspector with what the chat touched and what Claude may do.
///
/// Claude is one more client of the tools here: it reads items through their tools, each read shows as
/// a row that opens the item in its own window, and it asks before it changes anything.
public struct ChatRootView: View {
    @State private var model: ChatWindowModel
    @State private var showsInspector = true
    /// In an iPhone's layout, the inspector shows as a sheet.
    @State private var showsInspectorSheet = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    @Environment(\.toolReader) private var toolReader
    @Environment(\.toolLayout) private var layout

    /// The chats of `project`, with `focus` (a conversation id) selected, or the latest one. A later
    /// route's focus arrives as a focus request, which selects it without starting afresh.
    public init(project: Project, focus: String? = nil, store: ChatStore = .shared) {
        _model = State(initialValue: ChatWindowModel(project: project, focus: focus, store: store))
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
        ChatInspector(references: model.references)
    }

    /// The conversation picked, or a new one, over the field to write in.
    private var detail: some View {
        VStack(spacing: 0) {
            if let conversation = model.conversation {
                ScrollView {
                    ChatTranscript(conversation: conversation, isResponding: model.isResponding) { approval, allow in
                        model.decide(approval, allow: allow)
                    }
                    .padding(layout == .phone ? 16 : 24)
                }
                // A short chat starts at the top; a long one opens on its end and follows new turns.
                .defaultScrollAnchor(.top, for: .alignment)
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
                .id(conversation.id)
            } else {
                NewChatPrompt(projectName: model.project.name, suggestions: model.suggestions) { suggestion in
                    model.send(suggestion, reader: toolReader)
                }
            }
            ChatComposer(
                text: $model.draft,
                prompt: Text("Ask about \(model.project.name)…", bundle: #bundle, comment: "The composer's prompt: an item or a project"),
                isResponding: model.isResponding,
                send: { model.sendDraft(reader: toolReader) }
            ) {
                ProjectChip(project: model.project)
            }
            .padding(layout == .phone ? 12 : 16)
        }
        .background(.canvas)
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

    @AppStorage(ChatPreferences.ticketChangesKey) private var ticketChanges = ChangePermission.askFirst
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
            ChatPermissionsSection(ticketChanges: $ticketChanges, buildStarts: $buildStarts, identifier: "chat.inspector.permissions")
            Section {
                ModelRow(identifier: "chat.inspector.model")
                Text("Replies are samples until a model is connected.", bundle: #bundle)
                    .font(.caption)
                    .foregroundStyle(.textSecondary)
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
    ChatRootView(project: Project.samples[0], store: .transient())
}

#Preview("Chat, Dark", traits: .appChrome, .fixedLayout(width: 1240, height: 800)) {
    ChatRootView(project: Project.samples[0], store: .transient())
        .preferredColorScheme(.dark)
}

#Preview("New Chat", traits: .appChrome, .fixedLayout(width: 1000, height: 680)) {
    ChatRootView(project: Project.samples[3], store: .transient())
}

#Preview("Grouped", traits: .appChrome, .fixedLayout(width: 1240, height: 800)) {
    // Shop, whose sub projects have chats of their own.
    ChatRootView(project: Project.tree.project("SHOP") ?? Project.samples[0], store: .transient())
}

#Preview("Reading", traits: .appChrome, .fixedLayout(width: 1240, height: 800)) {
    // An engine that takes its time, so the reply stays on its way.
    let store = ChatStore(engine: SampleChatEngine(delay: .seconds(3_600)))
    let _ = store.send(
        "Is run 1288 enough to close ORD-142?", to: "chat-checkout", project: Project.samples[0], origin: nil,
        attachments: [], reader: ToolReader { _ in nil }
    )
    ChatRootView(project: Project.samples[0], focus: "chat-checkout", store: store)
}

#Preview("Approval Answered", traits: .appChrome, .fixedLayout(width: 1240, height: 800)) {
    let store = ChatStore.transient()
    let _ = store.decide("chat-checkout.comment", in: "chat-checkout", allow: false)
    ChatRootView(project: Project.samples[0], focus: "chat-checkout", store: store)
}

#Preview("iPad", traits: .padLayout, .fixedLayout(width: 820, height: 800)) {
    ChatRootView(project: Project.samples[0], store: .transient())
}

#Preview("iPhone", traits: .phoneLayout, .fixedLayout(width: 420, height: 800)) {
    ChatRootView(project: Project.samples[0], store: .transient())
}

#Preview("iPhone, Conversation", traits: .phoneLayout, .fixedLayout(width: 420, height: 800)) {
    ChatRootView(project: Project.samples[0], focus: "chat-checkout", store: .transient())
}

#Preview("iPhone, Dark", traits: .phoneLayout, .fixedLayout(width: 420, height: 800)) {
    ChatRootView(project: Project.samples[0], focus: "chat-checkout", store: .transient())
        .preferredColorScheme(.dark)
}

#Preview("Largest Text", traits: .largestText, .fixedLayout(width: 1240, height: 800)) {
    ChatRootView(project: Project.samples[0], store: .transient())
}

#Preview("New Chat, Largest Text", traits: .largestText, .fixedLayout(width: 1000, height: 680)) {
    ChatRootView(project: Project.samples[3], store: .transient())
}
