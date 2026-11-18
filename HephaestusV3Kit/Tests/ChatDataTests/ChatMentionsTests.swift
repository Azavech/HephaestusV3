import FileStorage
import Foundation
import MCPKit
import Testing
@testable import ChatData

/// docs/data.md › Mentioned ids.
@Suite("Mentioned ids")
@MainActor
struct ChatMentionsTests {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("A message's linked ids and the tickets it carries, Claude's reply outside a sub-agent; never a call, a result or a code block")
    func ids() throws {
        var message = UserItem(id: "U1", created: date, text: "Look at ORD-142, not `ORD-9` alone, and [PAY-3](https://x)\n\n```\nORD-7\n```",
                               sender: "Studio")
        message.references = [ChatItemReference(tool: "tickets", projectID: "ORD", focus: "ORD-B3", title: "ORD-B3"),
                              ChatItemReference(tool: "builds", projectID: "ORD", focus: "1288", title: "Run 1288")]
        message.linkedItems = [["kind": "ticket", "name": "HEPH-12"], ["kind": "doc", "name": "README.md"]]
        #expect(ChatMentions.ids(in: .user(message)) == ["ORD-142", "ORD-9", "ORD-B3", "HEPH-12"])
        let reply = AssistantItem(id: "A1", created: date, text: "Done: SHOP-4 and SHOP-B2.", messageID: "m1")
        #expect(ChatMentions.ids(in: .assistant(reply)) == ["SHOP-4", "SHOP-B2"])
        var nested = reply
        nested.parentToolUseID = "t1"
        #expect(ChatMentions.ids(in: .assistant(nested)).isEmpty, "A sub-agent's text doesn't count")
        let result = ToolResultItem(id: "t1#result", created: date, toolUseID: "t1", text: "ORD-142", isError: false)
        #expect(ChatMentions.ids(in: .toolResult(result)).isEmpty)
    }

    @Test("Chats are read for their ids when they load, and each new message adds its own; the latest updated first")
    func session() async throws {
        let world = try await ChatWorld()
        defer { Task { await world.close() } }
        let first = try await world.session.send("What about ORD-142?", references: [], to: nil, projectID: "ORD")
        let second = try await world.session.send("And ORD-142 with ORD-139", references: [], to: nil, projectID: "ORD")
        #expect(Set(world.session.chats(mentioning: "ORD-142").map(\.id)) == [first, second])
        #expect(world.session.chats(mentioning: "ORD-139").map(\.id) == [second])
        world.launcher.chats.forEach { $0.finish(.exited(0)) }

        // A new session reads them from the files.
        let again = ChatSession(projects: world.projects, tokens: world.tokens, launcher: world.launcher, runner: ChatRunner(), device: "Studio",
                                processEnvironment: [:], trash: .folder(world.root.appendingPathComponent("Trash")))
        await again.start(tools: [], port: 47998)
        try await world.until { again.chats(mentioning: "ORD-142").count == 2 }
        #expect(again.chats(mentioning: "ORD-139").map(\.id) == [second])
        #expect(again.chats(mentioning: "ORD-1").isEmpty)
    }
}
