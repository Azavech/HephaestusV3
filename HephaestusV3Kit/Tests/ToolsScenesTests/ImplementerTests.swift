import ChatData
import FileStorage
import Foundation
import MCPKit
import ProjectData
import TicketData
import Testing
@testable import ToolsScenes

/// docs/data.md › Implement chats: the checks the app makes before a chat starts, and the tools' errors and rows.
@Suite("Implementer")
@MainActor
struct ImplementerTests {
    private func implementer() -> Implementer {
        let projects = ProjectSession(dataFolder: nil)
        return Implementer(tickets: TicketSession(projects: projects, device: "Test"),
                           chats: ChatSession(projects: projects, tokens: MCPTokens(), device: "Test"))
    }

    @Test("A malformed or unknown ticket or bundle starts nothing")
    func unknown() async {
        let implementer = implementer()
        await #expect(throws: ChatError.invalid("\"ord\" is not a valid ticket id.")) { try await implementer.implementTicket("ord", settings: nil) }
        await #expect(throws: ChatError.notFound("Ticket ORD-1 not found.")) { try await implementer.implementTicket("ord-1", settings: nil) }
        await #expect(throws: ChatError.invalid("\"ORD-1\" is not a valid bundle id.")) { try await implementer.implementBundle("ORD-1", settings: nil) }
        await #expect(throws: ChatError.notFound("Bundle ORD-B1 not found.")) { try await implementer.implementBundle("ORD-B1", settings: nil) }
    }

    @Test("The library's refusals become the chat's, and the chat's the tools' codes")
    func errors() {
        #expect(Implementer.chatError(.conflict("ORD-1 is done; set another status to implement it.")) == .conflict("ORD-1 is done; set another status to implement it."))
        #expect(Implementer.chatError(.notFound("Ticket ORD-1 not found.")) == .notFound("Ticket ORD-1 not found."))
        #expect(Implementer.toolError(.conflict("x")) == ToolError(.conflict, "x"))
        #expect(Implementer.toolError(.unavailable("Cannot create the branch and worktree of ORD-1: git is not available")).code == .unavailable)
        #expect(Implementer.toolError(.notFound("Ticket ORD-1 not found.")).code == .notFound)
    }

    @Test("A call's row and card name the item, which opens in its Tickets window")
    func describe() {
        let text = Implementer.describe("ord-142")
        #expect(text.action == "Started the chat that implements ORD-142")
        #expect(text.request == "Claude wants to start a chat that implements ORD-142")
        #expect(text.item == ToolItem(tool: "tickets", projectID: "ORD", focus: "ORD-142", title: "ORD-142"))
        #expect(Implementer.describe("ORD-B3").item?.projectID == "ORD")
    }
}
