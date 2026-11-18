import FileStorage
import Foundation
import MCPKit
import TextFormats

/// The ticket and bundle ids a chat mentions, for the Mentioned In lists (docs/data.md › Mentioned ids), read
/// as V2 read them: the ids its messages and Claude's replies show as links, and the tickets and bundles its
/// messages carry. Never stored: computed from the transcripts at each launch.
public enum ChatMentions {
    /// The ids an item adds: a message's linked ids and the tickets and bundles it carries (V3's references and
    /// V2's linked items of kind `ticket` or `bundle`), and the linked ids of Claude's reply outside a sub-agent.
    /// Calls, results, thinking and questions add none.
    public static func ids(in item: ChatItem) -> Set<String> {
        switch item {
        case .user(let message):
            var ids = MarkdownItemIDs.linkedIDs(inMarkdown: message.text)
            for reference in message.references where reference.tool == "tickets" {
                ids.insert(reference.focus)
            }
            for linked in message.linkedItems.arrayValue ?? [] {
                if let kind = linked["kind"]?.stringValue, kind == "ticket" || kind == "bundle", let name = linked["name"]?.stringValue {
                    ids.insert(name)
                }
            }
            return ids
        case .assistant(let reply) where reply.parentToolUseID == nil:
            return MarkdownItemIDs.linkedIDs(inMarkdown: reply.text)
        default:
            return []
        }
    }

    /// The ids of a whole transcript.
    public static func ids(in items: [ChatItem]) -> Set<String> {
        items.reduce(into: []) { $0.formUnion(ids(in: $1)) }
    }
}

extension ChatSession {
    /// Reads, one transcript at a time and off the main actor, the ids of the chats not read yet; a scan asked for
    /// while one runs follows it.
    func scanMentions() {
        guard mentionScan == nil else {
            mentionRescan = true
            return
        }
        let pending = chats.keys.sorted().filter { !mentionsScanned.contains($0) }.compactMap { id in transcriptURL(id).map { (id, $0) } }
        guard !pending.isEmpty else { return }
        mentionScan = Task { [weak self] in
            for (id, url) in pending {
                let ids = await Task.detached(priority: .utility) {
                    ChatMentions.ids(in: Transcript.replay((try? Data(contentsOf: url)) ?? Data()))
                }.value
                guard let self else { return }
                // The chat's agents come with its ids, for the lists that show them under it.
                self.loadAgents(id)
                self.mentionsScanned.insert(id)
                if self.chats[id] != nil, !ids.isSubset(of: self.mentions[id] ?? []) {
                    self.mentions[id, default: []].formUnion(ids)
                }
            }
            guard let self else { return }
            self.mentionScan = nil
            if self.mentionRescan {
                self.mentionRescan = false
                self.scanMentions()
            }
        }
    }

    /// Adds the ids of an item just recorded.
    func noteMentions(of item: ChatItem, in chatID: String) {
        let ids = ChatMentions.ids(in: item)
        guard !ids.isEmpty, !ids.isSubset(of: mentions[chatID] ?? []) else { return }
        mentions[chatID, default: []].formUnion(ids)
    }

    /// Forgets the ids of chats gone.
    func dropMentions(keeping ids: some Sequence<String>) {
        let kept = Set(ids)
        if mentions.keys.contains(where: { !kept.contains($0) }) {
            mentions = mentions.filter { kept.contains($0.key) }
        }
        mentionsScanned.formIntersection(kept)
    }

    /// The chats that mention a ticket or bundle id, the latest updated first.
    public func chats(mentioning id: String) -> [LoadedChat] {
        mentions.compactMap { chatID, ids in ids.contains(id) ? chats[chatID] : nil }
            .sorted { ($0.file.updated, $0.id) > ($1.file.updated, $1.id) }
    }
}
