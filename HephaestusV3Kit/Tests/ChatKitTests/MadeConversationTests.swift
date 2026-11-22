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

    @Test("Each block is a row of its own, the same whatever its action: a word Claude writes draws its block again, not the turn")
    func transcriptRows() {
        let turn = ChatTurn(id: "T1", author: .claude, date: date, blocks: [ChatBlock(id: "b1", .text("Because")), ChatBlock(id: "b2", .text("And"))])
        var conversation = ChatConversation(id: "C", projectID: "ORD", title: "T", origin: nil, createdAt: date, turns: [turn])
        let rows = ChatTranscript.rows(of: conversation, compact: false, hidesWaitingApprovals: false)
        #expect(rows.map { $0.id } == ["T1#author", "b1", "b2"])
        #expect(rows.map { $0.top } == [0, 8, 8])
        conversation.turns[0].blocks[1] = ChatBlock(id: "b2", .text("And then"))
        let streamed = ChatTranscript.rows(of: conversation, compact: false, hidesWaitingApprovals: false)
        #expect(streamed[1] == rows[1] && streamed[2] != rows[2], "Only the block that changed differs")
        let view = ChatTranscriptRowView(row: rows[1], projectID: "ORD", compact: false, decide: { _, _ in })
        #expect(view == ChatTranscriptRowView(row: rows[1], projectID: "ORD", compact: false, decide: { _, _ in }, hover: { _ in }))
        #expect(view != ChatTranscriptRowView(row: rows[1], projectID: "ORD", compact: false, isMatch: true, decide: { _, _ in }))
    }
}

@Suite("Chats as the chat tools give them")
@MainActor
struct ChatJSONTests {
    @Test("A chat's JSON says whether it is closed, its mode, who started it, whether it may ask and its background work, as V2's")
    func fields() throws {
        let session = ChatSession(projects: ProjectSession(dataFolder: nil), tokens: MCPTokens(), device: "Studio")
        var file = ChatFile(id: "A", title: "Why", created: Date())
        file.closed = true
        file.orchestratorChatID = "B"
        file.questionsBlocked = true
        file.settings.permissionMode = "plan"
        session.chats = ["A": LoadedChat(file: file, projectID: "ORD")]
        session.backgroundWork = ["A"]
        let json = ChatTools.json(try #require(session.chats["A"]), session)
        #expect(json["closed"] == true && json["orchestrator"] == "B" && json["questionsBlocked"] == true)
        #expect(json["permissionMode"] == "plan" && json["backgroundWork"] == true && json["contextUsage"] == nil)
    }
}
