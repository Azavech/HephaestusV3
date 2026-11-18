import Foundation
import Observation

/// Each existing chat's unsent text and files, as V2 kept them by chat id: shared by every view of the chat,
/// in memory only (docs/ui/chat.md › Drafts). A new chat's draft, before it has an id, stays in its view.
@Observable
final class ChatDrafts {
    private var texts: [ChatConversation.ID: String] = [:]
    private var files: [ChatConversation.ID: [URL]] = [:]

    func text(of id: ChatConversation.ID) -> String {
        texts[id] ?? ""
    }

    /// A text that doesn't change notifies no view: a field writing back what it shows would draw again forever.
    func setText(_ text: String, of id: ChatConversation.ID) {
        let new: String? = text.isEmpty ? nil : text
        guard texts[id] != new else { return }
        texts[id] = new
    }

    func files(of id: ChatConversation.ID) -> [URL] {
        files[id] ?? []
    }

    func setFiles(_ urls: [URL], of id: ChatConversation.ID) {
        let new: [URL]? = urls.isEmpty ? nil : urls
        guard files[id] != new else { return }
        files[id] = new
    }
}

/// A view's composer: the draft of the chat it shows, the store's, or of its new chat, its own.
struct ComposerDraft {
    var newText = ""
    var newFiles: [URL] = []

    func text(of id: ChatConversation.ID?, in drafts: ChatDrafts) -> String {
        id.map(drafts.text(of:)) ?? newText
    }

    mutating func setText(_ text: String, of id: ChatConversation.ID?, in drafts: ChatDrafts) {
        if let id { drafts.setText(text, of: id) } else { newText = text }
    }

    func files(of id: ChatConversation.ID?, in drafts: ChatDrafts) -> [URL] {
        id.map(drafts.files(of:)) ?? newFiles
    }

    mutating func setFiles(_ urls: [URL], of id: ChatConversation.ID?, in drafts: ChatDrafts) {
        if let id { drafts.setFiles(urls, of: id) } else { newFiles = urls }
    }

    /// The new chat got its id: its draft becomes the chat's.
    mutating func adopt(_ id: ChatConversation.ID, in drafts: ChatDrafts) {
        drafts.setText(newText, of: id)
        drafts.setFiles(newFiles, of: id)
        newText = ""
        newFiles = []
    }

    /// After a message went from the chat `id` (nil for a new chat): its text goes unless it changed meanwhile,
    /// and the files it carried.
    mutating func clear(sentText: String, sentFiles: [URL], from id: ChatConversation.ID?, in drafts: ChatDrafts) {
        if text(of: id, in: drafts) == sentText { setText(String(), of: id, in: drafts) }
        setFiles(files(of: id, in: drafts).filter { !sentFiles.contains($0) }, of: id, in: drafts)
    }
}
