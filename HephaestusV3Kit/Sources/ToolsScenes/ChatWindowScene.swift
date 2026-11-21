import ChatKit
import SwiftUI
import ToolsFoundation

/// What a chat window shows: one chat, which never changes while the window is open. SwiftUI restores it with
/// the window.
struct ChatWindowValue: Codable, Hashable {
    let chatID: String
}

/// A chat window's content: the chat over the status bar, with its version, weekly usage and ladybug only
/// (docs/ui/chat.md › Chat windows).
/// The window is listed with its chat, for routes to bring it forward rather than open a second one.
struct ChatWindowScene: View {
    let value: ChatWindowValue

    @Environment(\.projectDirectory) private var directory
    @Environment(\.chatStore) private var store

    var body: some View {
        ChatWindowView(chatID: value.chatID)
            .frame(minWidth: 480, minHeight: 480)
            .statusBar(FeedbackSource(window: String(localized: "Chat", bundle: #bundle, comment: "A chat window's name, in the feedback's context"),
                                      project: project, item: title), countsChats: false)
            .background {
                WindowReader { window in WindowDirectory.shared.register(window, chat: value.chatID) }
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
    }

    private var project: Project? {
        store?.projectID(of: value.chatID).flatMap { directory.project($0) }
    }

    private var title: String? {
        store?.title(of: value.chatID)
    }
}
