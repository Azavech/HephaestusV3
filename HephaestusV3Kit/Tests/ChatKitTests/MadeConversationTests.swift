import FileStorage
import Foundation
import MCPKit
import Observation
import ProjectData
import Synchronization
import Testing
import ToolsFoundation
@testable import ChatData
@testable import ChatKit

/// docs/architecture.md › ChatKit: a conversation made once per change of its transcript, and the views of one chat
/// told of that chat's changes only.
@Suite("Conversations made once")
@MainActor
struct MadeConversationTests {
    private let date = ISODate.date(from: "2026-11-21T10:00:00Z")!

    /// A session with two chats, `A` and `B`, their transcripts read, without projects or processes.
    private func session() -> ChatSession {
        let session = ChatSession(projects: ProjectSession(dataFolder: nil), tokens: MCPTokens(), device: "Studio")
        session.chats = [
            "A": LoadedChat(file: ChatFile(id: "A", title: "Why", created: date), projectID: "ORD"),
            "B": LoadedChat(file: ChatFile(id: "B", title: "How", created: date), projectID: "ORD"),
        ]
        session.transcripts["A"] = [.user(UserItem(id: "U1", created: date, text: "Why?", sender: "Studio"))]
        session.transcripts["B"] = []
        return session
    }

    @Test("The turns are made again when the transcript changes, not at each read nor at each word streamed")
    func madeOnce() {
        let session = session()
        let store = LiveChatStore(session: session) { _, _ in nil }
        let first = store.made("A")
        #expect(store.made("A").key == first.key)
        #expect(store.conversation("A")?.turns.map(\.author) == [.user])

        session.record(.assistant(AssistantItem(id: "m#1", created: date, text: "Because", messageID: "m")), in: "A")
        let second = store.made("A")
        #expect(second.key.revision > first.key.revision)
        #expect(store.conversation("A")?.turns.map(\.author) == [.user, .claude])

        session.streaming["A"] = StreamingText(itemID: "m#2", text: "And")
        session.streaming["A"]?.text += " so"
        let streamed = store.conversation("A")
        #expect(streamed?.turns.count == 2 && streamed?.turns.last?.blocks.map(\.content) == [.text("Because"), .text("And so")])
        #expect(store.made("A").key == second.key, "The text streaming is added to the turns made")

        // The item streamed comes: its text shows once.
        session.streaming["A"] = nil
        session.record(.assistant(AssistantItem(id: "m#2", created: date, text: "And so", messageID: "m")), in: "A")
        #expect(store.conversation("A")?.turns.last?.blocks.map(\.content) == [.text("Because"), .text("And so")])
    }

    @Test("A view of one chat isn't told of another chat's items and words; it is of its own")
    func otherChats() {
        let session = session()
        let store = LiveChatStore(session: session) { _, _ in nil }
        let told = Mutex(false)
        withObservationTracking { _ = store.conversation("B") } onChange: { told.withLock { $0 = true } }
        session.streaming["A"] = StreamingText(itemID: "m#2", text: "And")
        session.record(.assistant(AssistantItem(id: "m#1", created: date, text: "Because", messageID: "m")), in: "A")
        #expect(!told.withLock { $0 })
        session.streaming["B"] = StreamingText(itemID: "m#3", text: "Hi")
        #expect(told.withLock { $0 })
    }

    @Test("A turn view is the same whatever its action: only a turn that changed is drawn again")
    func turnViews() {
        let turn = ChatTurn(id: "T1", author: .claude, date: date, blocks: [ChatBlock(id: "b1", .text("Because"))])
        var changed = turn
        changed.blocks.append(ChatBlock(id: "b2", .text("And")))
        let view = ChatTurnView(turn: turn, projectID: "ORD", compact: false, decide: { _, _ in })
        #expect(view == ChatTurnView(turn: turn, projectID: "ORD", compact: false, decide: { _, _ in }))
        #expect(view != ChatTurnView(turn: changed, projectID: "ORD", compact: false, decide: { _, _ in }))
        #expect(view != ChatTurnView(turn: turn, projectID: "ORD", compact: false, decide: { _, _ in }, matches: ["b1"]))
    }
}
