import ChatData
import FileStorage
import Foundation
import MCPKit
import ProjectData
import SwiftUI
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
        #expect(blocks.count == 8, "A stop shows nothing; a sub-agent's call is a step of its call")
        #expect(blocks[0] == .notice(ChatNotice(text: "Careful", level: .warning)))
        #expect(blocks[1].row == .call(ChatToolCall(action: "Read ticket ORD-142", reference: ChatReference(tool: .tickets, projectID: "ORD", focus: "ORD-142", title: "ORD-142"))))
        #expect(blocks[2].row == .call(ChatToolCall(action: "Used Bash", reference: nil, detail: "boom", failed: true)))
        guard case .call(let bash) = blocks[2], let details = bash.details else { Issue.record("no details"); return }
        #expect(details.name == "Bash" && details.server == nil && details.input == [ChatToolInput(text: "ls", language: "shell")])
        #expect(details.result == "boom\nmore" && !details.isRunning)
        #expect(details.steps.map(\.id) == ["a#0"], "The sub-agent's Grep is a step of the Bash call that started it")
        #expect(blocks[3] == .thinking("Hmm"))
        guard case .approval(let approval) = blocks[4] else { Issue.record("no card"); return }
        #expect(approval.request == "Claude wants to comment on ORD-142" && approval.preview == "Done" && approval.decision == nil)
        #expect(approval.channel == ChatApproval.Channel(.tickets) && approval.id == "r1")
        #expect(blocks[5] == .text("**Done**"))
        guard case .notice(let done) = blocks[6] else { Issue.record("no end"); return }
        #expect(done.level == .done && done.text.hasPrefix("Done · "), "A turn that ended well says so, without its cost")
        #expect(blocks[7] == .notice(ChatNotice(text: "error_max_turns", level: .error)))
    }

    @Test("A call's input: a command, an edit's two texts, a file's content, otherwise JSON; a call waiting shows it runs")
    func inputs() {
        func use(_ name: String, _ input: JSONValue, server: String? = nil) -> ToolUseItem {
            ToolUseItem(id: name, created: date, toolUseID: name, name: name, server: server, input: input)
        }
        #expect(LiveChatStore.input(use("Edit", ["file_path": "/r/a.swift", "old_string": "a", "new_string": "b"]))
                == [ChatToolInput(title: "Old", text: "a", language: "swift"), ChatToolInput(title: "New", text: "b", language: "swift")])
        #expect(LiveChatStore.input(use("Write", ["file_path": "/r/notes", "content": "x"])) == [ChatToolInput(text: "x", language: nil)])
        #expect(LiveChatStore.input(use("get_ticket", ["ticketID": "ORD-1"], server: "hephaestus"))
                == [ChatToolInput(text: "{\n  \"ticketID\" : \"ORD-1\"\n}", language: "json")])
        let waiting = store.turns([.toolUse(use("Bash", ["command": "sleep 9"]))], streaming: nil, isRunning: true)
        guard case .call(let call)? = waiting.first?.blocks.first?.content else { Issue.record("no call"); return }
        #expect(call.details?.isRunning == true && call.details?.result == nil)
    }

    @Test("Claude's turn is captioned with the model and effort of its first text")
    func caption() {
        let turns = store.turns([.assistant(AssistantItem(id: "m#0", created: date, text: "Hi", messageID: "m", model: "claude-opus-5-5", effort: .xhigh))],
                                streaming: nil)
        #expect(turns.first?.caption?.effort == "Extra High" && turns.first?.caption?.model != nil)
        #expect(ChatAuthorRow<EmptyView>.caption(ChatTurnCaption(model: "Opus 5.5", effort: "Extra High")) == "(Opus 5.5 · Extra High)")
        #expect(ChatAuthorRow<EmptyView>.caption(ChatTurnCaption()) == nil)
    }

    @Test("Find: the blocks that hold the query, ignoring case")
    func find() {
        let conversation = ChatConversation(id: "C", projectID: "ORD", title: "", origin: nil, createdAt: date, turns: store.turns(items(), streaming: nil))
        #expect(ChatFind.matches(of: "DONE", in: conversation) == ["perm-r1", "m#3", "R1"], "The card's preview, the text, the Done line")
        #expect(ChatFind.matches(of: "boom", in: conversation) == ["m#1"], "A call's result")
        #expect(ChatFind.matches(of: "  ", in: conversation).isEmpty)
    }

    @Test("A message's files show from the project's .hephaestus/; a feedback message of 1.0.31 to 1.0.33 gives those its lines name")
    func messageFiles() {
        let shot = MessageAttachment.stored(id: "8FF0CD02-5ECC-41D0-81AB-0995DF0C8767", name: "screenshot.png", chatID: "C1", size: 384_595)
        let broken = MessageAttachment(id: "B", name: "x.txt", path: "../x.txt", contentType: "text/plain", size: 0)
        let message = UserItem(id: "U1", created: date, text: "Look", sender: "Studio", attachments: [shot, broken])
        let files = store.turns([.user(message)], streaming: nil, root: "/Users/you/Repo", chatID: "C1")[0].files
        #expect(files.map(\.name) == ["screenshot.png", "x.txt"])
        #expect(files[0].url?.path == "/Users/you/Repo/.hephaestus/chats/C1/8FF0CD02-5ECC-41D0-81AB-0995DF0C8767-screenshot.png")
        #expect(files[0].contentType == .png && files[0].size == 384_595)
        #expect(files[1].url == nil, "A path out of the chats' folders opens nothing")

        let legacy = UserItem(id: "U2", created: date, text: """
            /hephaestus-skills:report-feedback
            Black sidebar

            Feedback context:
            - Screenshot: /Users/you/Repo/.hephaestus/chats/C1/8FF0CD02-5ECC-41D0-81AB-0995DF0C8767-screenshot.png
            """, sender: "Studio")
        let found = store.turns([.user(legacy)], streaming: nil, root: "/Users/you/Repo", chatID: "C1")[0].files
        #expect(found.map(\.name) == ["screenshot.png"] && found[0].size == nil)
        #expect(store.turns([.user(legacy)], streaming: nil)[0].files.isEmpty, "Without the project's folder, no files")
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
            .permissionRequest(PermissionRequestItem(requestID: "r3", created: date, toolName: "Bash", input: ["command": "ls"])),
        ], streaming: nil)
        guard case .approval(let project) = turns[0].blocks[0].content, case .approval(let bash) = turns[0].blocks[1].content else {
            Issue.record("no cards"); return
        }
        #expect(project.channel == .projects && project.reference == nil)
        #expect(bash.channel == nil && bash.request == "Claude wants to use Bash" && bash.preview == "{\n  \"command\" : \"ls\"\n}")
    }

    @Test("The file tools' calls name their file from the project's folder; their cards show the change")
    func files() {
        let root = "/Users/you/Repo"
        let turns = store.turns([
            .toolUse(ToolUseItem(id: "m#0", created: date, toolUseID: "t1", name: "Read", server: nil, input: ["file_path": "/Users/you/Repo/Sources/App.swift"])),
            .toolResult(ToolResultItem(id: "t1#result", created: date, toolUseID: "t1", text: "     1\timport SwiftUI", isError: false)),
            .toolUse(ToolUseItem(id: "m#1", created: date, toolUseID: "t2", name: "Grep", server: nil, input: ["pattern": "screenshot"])),
            .toolResult(ToolResultItem(id: "t2#result", created: date, toolUseID: "t2", text: "Found 3 files\nSources/A.swift", isError: false)),
            .toolUse(ToolUseItem(id: "m#2", created: date, toolUseID: "t3", name: "Glob", server: nil, input: ["pattern": "**/*.swift", "path": "/Users/you/Repo/Sources"])),
            .toolUse(ToolUseItem(id: "m#3", created: date, toolUseID: "t4", name: "Edit", server: nil, input: ["file_path": "Sources/App.swift", "old_string": "a", "new_string": "b"])),
            .toolUse(ToolUseItem(id: "m#4", created: date, toolUseID: "t5", name: "Write", server: nil, input: ["file_path": "/tmp/x", "content": "hi"])),
            .permissionRequest(PermissionRequestItem(requestID: "r1", created: date, toolName: "Edit",
                                                     input: ["file_path": "/Users/you/Repo/Sources/App.swift", "old_string": "a\nb", "new_string": "c"])),
            .permissionRequest(PermissionRequestItem(requestID: "r2", created: date, toolName: "Read", input: ["file_path": "/etc/hosts"])),
        ], streaming: nil, root: root)
        let blocks = turns[0].blocks.map(\.content)
        #expect(blocks[0].row == .call(ChatToolCall(action: "Read Sources/App.swift", reference: nil, detail: "/Users/you/Repo/Sources/App.swift")))
        #expect(blocks[1].row == .call(ChatToolCall(action: "Searched for “screenshot”", reference: nil, detail: "Found 3 files")))
        #expect(blocks[2].row == .call(ChatToolCall(action: "Listed the files matching **/*.swift in Sources", reference: nil, detail: "/Users/you/Repo/Sources")))
        #expect(blocks[3].row == .call(ChatToolCall(action: "Edited Sources/App.swift", reference: nil, detail: "/Users/you/Repo/Sources/App.swift")))
        #expect(blocks[4].row == .call(ChatToolCall(action: "Wrote /tmp/x", reference: nil, detail: "/tmp/x")))
        guard case .approval(let edit) = blocks[5], case .approval(let read) = blocks[6] else { Issue.record("no cards"); return }
        #expect(edit.request == "Claude wants to edit Sources/App.swift" && edit.preview == "- a\n- b\n+ c" && edit.channel == nil)
        #expect(read.request == "Claude wants to read /etc/hosts" && read.preview == nil)
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

    @Test("An internal skill's run reads, whatever the settings say; it changes nothing and opens no window")
    func internalSkill() async {
        let chats = bareSession()
        let skill = MCPCaller.internalSkill("set-ticket-title")
        defaults.set("always", forKey: ChatPreferences.ticketChangesKey)
        #expect(await ChatGate.check(skill, operation(.read), [:], chats: chats, defaults: defaults) == nil)
        for permission in [ToolPermission.changeTickets, .deleteTickets, .renameChats, .changeProjects, .callAPIs, .startBuilds] {
            #expect(await ChatGate.check(skill, operation(permission), [:], chats: chats, defaults: defaults)
                == ToolError(.forbidden, "An internal skill's run only reads."))
        }
        let open = ToolOperation(name: "open_in_app", description: "", inputSchema: .object(), permission: .read) { _ throws(ToolError) in .null }
        #expect(await ChatGate.check(skill, open, [:], chats: chats, defaults: defaults)?.code == .forbidden)
    }

    @Test("A skill run's token is the skill's until it ends")
    func skillToken() {
        let tokens = MCPTokens()
        let token = tokens.issue(forSkill: "set-ticket-title")
        #expect(tokens.caller(for: token) == .internalSkill("set-ticket-title"))
        #expect(tokens.caller(for: token)?.chatID == nil)
        tokens.revoke(token)
        #expect(tokens.caller(for: token) == nil)
    }
}

private extension ChatBlock.Content {
    /// A call's row without its details, to compare what the row says.
    var row: ChatBlock.Content {
        if case .call(var call) = self {
            call.details = nil
            return .call(call)
        }
        return self
    }
}
