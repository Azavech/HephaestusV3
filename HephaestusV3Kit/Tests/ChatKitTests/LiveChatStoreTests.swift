import ChatData
import FileStorage
import Foundation
import MCPKit
import ProjectData
import Testing
import ToolsFoundation
@testable import ChatKit

/// A chat session without projects or processes: enough for the turns and the gate.
@MainActor
private func bareSession() -> ChatSession {
    ChatSession(projects: ProjectSession(dataFolder: nil), tokens: MCPTokens(), device: "Studio")
}

private let date = ISODate.date(from: "2026-11-14T10:00:00Z")!

@Suite("Chats as turns")
@MainActor
struct LiveChatTurnsTests {
    private let store = LiveChatStore(session: bareSession()) { name, input in
        switch name {
        case "get_ticket":
            let id = input["ticketID"]?.stringValue ?? ""
            return ToolCallText(action: "Read ticket \(id)", item: ToolItem(tool: "tickets", projectID: "ORD", focus: id, title: id))
        case "add_comment":
            return ToolCallText(action: "Commented on ORD-142", request: "Claude wants to comment on ORD-142", preview: input["text"]?.stringValue,
                                item: ToolItem(tool: "tickets", projectID: "ORD", focus: "ORD-142", title: "ORD-142"))
        case "create_project":
            return ToolCallText(action: "Added", request: "Claude wants to add the project Web", item: ToolItem(tool: "projects", projectID: "WEB", focus: "", title: "Web"))
        default:
            return nil
        }
    }

    private func items() -> [ChatItem] {
        [
            .user(UserItem(id: "U1", created: date, text: "Why?", sender: "Studio",
                           references: [ChatItemReference(tool: "tickets", projectID: "ORD", focus: "ORD-142", title: "ORD-142"),
                                        ChatItemReference(tool: "project", projectID: "ORD", focus: "", title: "Orders")])),
            .system(SystemItem(id: "S1", created: date, text: "Careful", level: .warning)),
            .toolUse(ToolUseItem(id: "m#0", created: date, toolUseID: "t1", name: "get_ticket", server: "hephaestus", input: ["ticketID": "ORD-142"])),
            .toolResult(ToolResultItem(id: "t1#result", created: date, toolUseID: "t1", text: "{}", isError: false)),
            .toolUse(ToolUseItem(id: "m#1", created: date, toolUseID: "t2", name: "Bash", server: nil, input: ["command": "ls"])),
            .toolResult(ToolResultItem(id: "t2#result", created: date, toolUseID: "t2", text: "boom\nmore", isError: true)),
            .toolUse(ToolUseItem(id: "a#0", created: date, toolUseID: "t3", name: "Grep", server: nil, input: [:], parentToolUseID: "t2")),
            .thinking(ThinkingItem(id: "m#2", created: date, text: "Hmm")),
            .permissionRequest(PermissionRequestItem(requestID: "r1", created: date, toolName: "mcp__hephaestus__add_comment", input: ["text": "Done"])),
            .assistant(AssistantItem(id: "m#3", created: date, text: "**Done**", messageID: "m")),
            .result(ResultItem(id: "R1", created: date, durationMs: 5, isError: false)),
            .result(ResultItem(id: "R2", created: date, durationMs: 5, isError: true, summary: "Stopped by the user.")),
            .result(ResultItem(id: "R3", created: date, durationMs: 5, isError: true, summary: "error_max_turns")),
        ]
    }

    @Test("A message is the user's turn, with its items but not the project; what follows is Claude's")
    func turns() {
        let turns = store.turns(items(), streaming: nil)
        #expect(turns.map(\.author) == [.user, .claude])
        #expect(turns[0].attachments.map(\.title) == ["ORD-142"])
        let blocks = turns[1].blocks.map(\.content)
        #expect(blocks.count == 6, "Sub-agents, thinking, a turn that ended well and a stop show nothing")
        #expect(blocks[0] == .notice(ChatNotice(text: "Careful", level: .warning)))
        #expect(blocks[1] == .call(ChatToolCall(action: "Read ticket ORD-142", reference: ChatReference(tool: .tickets, projectID: "ORD", focus: "ORD-142", title: "ORD-142"))))
        #expect(blocks[2] == .call(ChatToolCall(action: "Used Bash", reference: nil, detail: "boom", failed: true)))
        guard case .approval(let approval) = blocks[3] else { Issue.record("no card"); return }
        #expect(approval.request == "Claude wants to comment on ORD-142" && approval.preview == "Done" && approval.decision == nil)
        #expect(approval.channel == ChatApproval.Channel(.tickets) && approval.id == "r1")
        #expect(blocks[4] == .text("**Done**"))
        #expect(blocks[5] == .notice(ChatNotice(text: "error_max_turns", level: .error)))
    }

    @Test("Streamed text ends Claude's turn until its item comes")
    func streaming() {
        let streamed = store.turns(Array(items().prefix(1)), streaming: StreamingText(itemID: "m#9", text: "Wri"))
        #expect(streamed.last?.blocks.last?.content == .text("Wri"))
        let done = store.turns(Array(items().prefix(1)) + [.assistant(AssistantItem(id: "m#9", created: date, text: "Written", messageID: "m"))],
                               streaming: StreamingText(itemID: "m#9", text: "Written"))
        #expect(done.last?.blocks.count == 1)
    }

    @Test("A card of a project's change goes through Projects; one of the CLI's own shows its input")
    func channels() {
        let turns = store.turns([
            .permissionRequest(PermissionRequestItem(requestID: "r2", created: date, toolName: "mcp__hephaestus__create_project", input: [:])),
            .permissionRequest(PermissionRequestItem(requestID: "r3", created: date, toolName: "Write", input: ["file_path": "/tmp/x"])),
        ], streaming: nil)
        guard case .approval(let project) = turns[0].blocks[0].content, case .approval(let write) = turns[0].blocks[1].content else {
            Issue.record("no cards"); return
        }
        #expect(project.channel == .projects && project.reference == nil)
        #expect(write.channel == nil && write.request == "Claude wants to use Write" && write.preview == "{\n  \"file_path\" : \"/tmp/x\"\n}")
    }
}

@Suite("What a chat's Claude may do")
@MainActor
struct ChatGateTests {
    private let defaults = UserDefaults(suiteName: "ChatGateTests-\(UUID().uuidString)")!
    private let operation = { (permission: ToolPermission) in
        ToolOperation(name: "x", description: "", inputSchema: .object(), permission: permission) { _ throws(ToolError) in .null }
    }

    @Test("The external token and reads are never asked; Never refuses; Always runs; Ask First waits for the card")
    func rules() async {
        let chats = bareSession()
        #expect(await ChatGate.check(.external, operation(.changeTickets), [:], chats: chats, defaults: defaults) == nil)
        #expect(await ChatGate.check(.chat("C"), operation(.read), [:], chats: chats, defaults: defaults) == nil)
        #expect(await ChatGate.check(.chat("C"), operation(.renameChats), [:], chats: chats, defaults: defaults) == nil)
        defaults.set("never", forKey: ChatPreferences.ticketChangesKey)
        #expect(await ChatGate.check(.chat("C"), operation(.changeTickets), [:], chats: chats, defaults: defaults)?.code == .forbidden)
        #expect(await ChatGate.check(.chat("C"), operation(.deleteTickets), [:], chats: chats, defaults: defaults)?.code == .forbidden)
        defaults.set("always", forKey: ChatPreferences.ticketChangesKey)
        #expect(await ChatGate.check(.chat("C"), operation(.changeTickets), [:], chats: chats, defaults: defaults) == nil)
        // A deletion asks even under Always; a chat without a process can't show the card, so it's refused.
        #expect(await ChatGate.check(.chat("C"), operation(.deleteTickets), [:], chats: chats, defaults: defaults)
            == ToolError(.forbidden, "The user didn't allow this call."))
        #expect(await ChatGate.check(.chat("C"), operation(.changeProjects), [:], chats: chats, defaults: defaults)?.code == .forbidden,
                "Projects default to Ask First")
    }
}
