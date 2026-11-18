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
