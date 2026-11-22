import AZDesign
import ChatData
import SwiftUI
import ToolsFoundation

/// One chat in a window of its own, V2's chat window (docs/ui/chat.md › Chat windows): its transcript, cards and
/// composer, as the panel shows them, without the panel's header; the window's title is the chat's, its
/// subtitle the project's name. The window closes when the chat is deleted.
public struct ChatWindowView: View {
    let chatID: String
    /// The samples' store, for previews and captures; the app's comes from the environment.
    private var sampleStore: (any ChatStore)?

    @Environment(\.chatStore) private var store
    @Environment(\.projectDirectory) private var directory
    @Environment(\.dismiss) private var dismiss
    @State private var model: ChatPanelModel?
    /// V2's chat window menu: the title being typed for Rename, the confirmation asked, and why an action failed.
    @State private var newTitle: String?
    @State private var confirmsClose = false
    @State private var confirmsDelete = false
    @State private var failure: String?

    public init(chatID: String) {
        self.chatID = chatID
    }

    init(chatID: String, samples: any ChatStore) {
        self.chatID = chatID
        sampleStore = samples
    }

    public var body: some View {
        let conversation = model?.store.conversation(chatID)
        let project = conversation.flatMap { directory.project($0.projectID) }
        Group {
            if let model, let conversation, let project {
                ChatPanel(project: project, origin: conversation.origin ?? .dashboard, subject: nil, model: model, hide: {}, showsHeader: false)
            } else if directory.state == .loading || model == nil {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("chat.window.loading")
            } else {
                ContentUnavailableView {
                    Label(String(localized: "Chat Not Found", bundle: #bundle), systemImage: ToolKind.chat.symbol)
                } description: {
                    Text("It was deleted, or its project isn't loaded.", bundle: #bundle)
                }
                .accessibilityIdentifier("chat.window.notFound")
            }
        }
        .background(.canvas)
        .toolbar {
            if let conversation, let store = model?.store {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button(String(localized: "Rename…", bundle: #bundle)) { newTitle = conversation.title }
                        if conversation.closed {
                            Button(String(localized: "Reopen", bundle: #bundle, comment: "Reopens a closed chat")) {
                                act { () throws(ChatSendError) in try store.reopen(chatID) }
                            }
                        } else {
                            Button(String(localized: "Close", bundle: #bundle, comment: "Closes a chat")) { confirmsClose = true }
                        }
                        Divider()
                        Button(String(localized: "Delete…", bundle: #bundle), role: .destructive) { confirmsDelete = true }
                    } label: {
                        Label(String(localized: "More", bundle: #bundle), systemImage: "ellipsis.circle")
                    }
                    .help(String(localized: "More", bundle: #bundle))
                    .accessibilityIdentifier("chat.window.more")
                }
            }
        }
        .alert(String(localized: "Rename Chat", bundle: #bundle), isPresented: Binding(get: { newTitle != nil }, set: { if !$0 { newTitle = nil } })) {
            TextField(String(localized: "Title", bundle: #bundle), text: Binding(get: { newTitle ?? "" }, set: { newTitle = $0 }))
            Button(String(localized: "Rename", bundle: #bundle)) {
                let title = newTitle ?? ""
                if let store = model?.store { act { () throws(ChatSendError) in try store.rename(chatID, to: title) } }
            }
            .keyboardShortcut(.defaultAction)
            Button(String(localized: "Cancel", bundle: #bundle), role: .cancel) { newTitle = nil }
        }
        .confirmationDialog(String(localized: "Close the chat “\(conversation?.title ?? "")”?", bundle: #bundle), isPresented: $confirmsClose) {
            Button(String(localized: "Close", bundle: #bundle, comment: "Closes a chat")) {
                if let store = model?.store { act { () throws(ChatSendError) in try store.close(chatID) } }
            }
            Button(String(localized: "Cancel", bundle: #bundle), role: .cancel) {}
        }
        .confirmationDialog(String(localized: "Delete the chat “\(conversation?.title ?? "")”?", bundle: #bundle), isPresented: $confirmsDelete) {
            Button(String(localized: "Delete", bundle: #bundle), role: .destructive) {
                if let store = model?.store { act { () throws(ChatSendError) in try store.delete(chatID) } }
            }
            Button(String(localized: "Cancel", bundle: #bundle), role: .cancel) {}
        } message: {
            Text("Its transcript and files move to the Trash.", bundle: #bundle)
        }
        .alert(String(localized: "The Change Failed", bundle: #bundle), isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button(String(localized: "OK", bundle: #bundle)) { failure = nil }
        } message: {
            Text(verbatim: failure ?? "")
        }
        .navigationTitle(Text(verbatim: conversation?.title ?? ""))
        .navigationSubtitle(Text(verbatim: project?.name ?? ""))
        .onAppear {
            guard model == nil, let store = sampleStore ?? store else { return }
            let model = ChatPanelModel(chats: store)
            model.conversationID = chatID
            self.model = model
        }
        // A chat deleted while its window shows it takes the window with it.
        .onChange(of: conversation == nil) { wasShown, isGone in
            if !wasShown && isGone { dismiss() }
        }
        .accessibilityIdentifier("chat.window")
    }

    /// Runs one of the menu's actions; a refusal shows in an alert.
    private func act(_ action: () throws(ChatSendError) -> Void) {
        do throws(ChatSendError) {
            try action()
        } catch {
            failure = error.message
        }
    }
}

#Preview("Chat Window", traits: .fixedLayout(width: 720, height: 820)) {
    ChatWindowView(chatID: "chat-checkout", samples: SampleChatStore.transient())
}

#Preview("Chat Window, Dark", traits: .fixedLayout(width: 720, height: 820)) {
    ChatWindowView(chatID: "chat-release-notes", samples: SampleChatStore.transient())
        .preferredColorScheme(.dark)
}

#Preview("Chat Not Found", traits: .fixedLayout(width: 720, height: 500)) {
    ChatWindowView(chatID: "chat-gone", samples: SampleChatStore.transient())
}
