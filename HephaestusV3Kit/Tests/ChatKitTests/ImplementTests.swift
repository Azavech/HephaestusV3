import FileStorage
import Foundation
import MCPKit
import ProjectData
import Testing
import ToolsFoundation
@testable import ChatData
@testable import ChatKit

/// docs/mcp.md › Permissions (a chat's own items) and docs/ui/tickets.md › Implement sheet.
@Suite("Implement chats in ChatKit")
@MainActor
struct ImplementChatKitTests {
    private let defaults = UserDefaults(suiteName: "ImplementChatKitTests-\(UUID().uuidString)")!
    private let change = ToolOperation(name: "set_ticket_status", description: "", inputSchema: .object(), permission: .changeTickets) { _ throws(ToolError) in .null }
    private let date = ISODate.date(from: "2026-11-20T10:00:00Z")!

    /// A session with a ticket chat of ORD-142 (`T`), a bundle chat of ORD-B3 (`B`) and a project chat (`P`), without processes.
    private func session() -> ChatSession {
        let chats = ChatSession(projects: ProjectSession(dataFolder: nil), tokens: MCPTokens(), device: "Studio")
        var ticket = ChatFile(id: "T", title: "Implement ORD-142", kind: .ticket, created: date)
        ticket.ticketID = "ORD-142"
        var bundle = ChatFile(id: "B", title: "Implement All ORD-B3", kind: .bundle, created: date)
        bundle.bundleID = "ORD-B3"
        chats.chats = [
            "T": LoadedChat(file: ticket, projectID: "ORD"), "B": LoadedChat(file: bundle, projectID: "ORD"),
            "P": LoadedChat(file: ChatFile(id: "P", title: "Hi", created: date), projectID: "ORD"),
        ]
        return chats
    }

    private func check(_ chat: String, _ arguments: JSONValue, _ chats: ChatSession, mode: ChatPermissionMode? = nil) async -> ToolError? {
        await ChatGate.check(.chat(chat), change, arguments, chats: chats, defaults: defaults, mode: mode,
                             bundleTickets: { $0 == "ORD-B3" ? ["ORD-141", "ORD-142"] : nil })
    }

    @Test("Under Ask First an implement chat changes its own items without a card; anything else still asks; Never and Plan Only still refuse")
    func ownItems() async {
        let chats = session()
        defaults.set("askFirst", forKey: ChatPreferences.ticketChangesKey)
        #expect(await check("T", ["ticketID": "ORD-142", "status": "review"], chats) == nil)
        #expect(await check("T", ["ticketID": "ord-142"], chats) == nil, "Ids are read in capitals")
        #expect(await check("B", ["bundleID": "ORD-B3"], chats) == nil)
        #expect(await check("B", ["ticketID": "ORD-141"], chats) == nil, "A ticket of the bundle")
        // The others would show a card: without a process to show it in, the call is refused.
        let asked = ToolError(.forbidden, "The user didn't allow this call.")
        #expect(await check("T", ["ticketID": "ORD-141"], chats) == asked)
        #expect(await check("B", ["ticketID": "ORD-9"], chats) == asked)
        #expect(await check("P", ["ticketID": "ORD-142"], chats) == asked)
        #expect(await check("T", ["projectID": "ORD"], chats) == asked, "A call that names no item asks")
        #expect(await check("T", ["ticketID": "ORD-142"], chats, mode: .plan)?.message == "The chat is in Plan Only: Claude plans and changes nothing.")
        defaults.set("never", forKey: ChatPreferences.ticketChangesKey)
        #expect(await check("T", ["ticketID": "ORD-142"], chats)?.code == .forbidden)
    }

    @Test("The sheet starts on its settings, keeps them and the reason after a failure, and waits for the CLI")
    func sheet() async {
        let target = ImplementTarget(.bundle, id: "ORD-B3", projectID: "ORD", title: "Checkout reliability")
        var cli = FeedbackCLI.checking
        var started: [ChatSettings] = []
        var fails = true
        let model = ImplementModel(target: target, settings: ChatSettings(model: "opus", effort: .medium), cli: { cli }) { settings throws(ChatError) in
            started.append(settings)
            if fails { throw .conflict("ORD-B3 is in progress; set it to To Do to implement it.") }
            return "CHAT"
        }
        #expect(model.heading == "Implement All ORD-B3")
        #expect(!model.canStart && model.cliMessage == "Checking the Claude CLI…")
        #expect(await model.start() == nil && started.isEmpty)
        cli = .available
        model.settings.ultracode = true
        #expect(model.canStart && model.cliMessage == nil)
        #expect(await model.start() == nil)
        #expect(model.failure == "ORD-B3 is in progress; set it to To Do to implement it." && model.settings.ultracode)
        fails = false
        #expect(await model.start() == "CHAT")
        #expect(model.failure == nil && started.count == 2 && started.allSatisfy { $0.model == "opus" && $0.ultracode })
        let ticket = ImplementModel(target: ImplementTarget(.ticket, id: "ORD-142", projectID: "ORD", title: "Retry storm"),
                                    settings: ChatSettings(), cli: { .available }) { _ throws(ChatError) in "C" }
        #expect(ticket.heading == "Implement ORD-142")
    }
}
