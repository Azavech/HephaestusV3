import ChatData
import MCPKit
import Foundation
import Synchronization
import Testing
import ToolsFoundation
@testable import ChatKit

// MARK: - Doubles

/// Replies at once with `blocks`, and keeps what it was asked.
final class MockChatEngine: ChatEngine {
    var repliesAreSamples = false
    var blocks = [ChatBlock(.text("A reply."))]
    private(set) var messages: [(text: String, attachments: [ChatReference], projectID: Project.ID)] = []

    func reply(to message: String, attachments: [ChatReference], project: Project, reader: ToolReader) async -> [ChatBlock] {
        messages.append((message, attachments, project.id))
        return blocks
    }
}

/// Reads what `readings` knows, by the item's focus, as a tool's read function would.
private func reader(_ readings: [String: ToolReading] = [:]) -> ToolReader {
    ToolReader { reference in readings[reference.focus] }
}

private let orders = Project.sample("ORD")!
private let ord142 = ChatReference(tool: .tickets, projectID: "ORD", focus: "ORD-142", title: "ORD-142")
private let run1288 = ChatReference(tool: .builds, projectID: "ORD", focus: "1288", title: "Run 1288")

/// A conversation of `project` whose last turn is `minutesAgo` old.
private func conversation(_ id: String, project: Project.ID = "ORD", minutesAgo: Int, turns: [ChatTurn]? = nil) -> ChatConversation {
    let date = SampleClock.date(minutes: -minutesAgo)
    return ChatConversation(
        id: id, projectID: project, title: id, origin: nil, createdAt: date,
        turns: turns ?? [ChatTurn(id: "\(id).1", author: .user, date: date, blocks: [ChatBlock(.text("Hello"))])]
    )
}

// MARK: - Store

@Suite("Chat store")
struct ChatStoreTests {
    @Test("The first message starts a conversation titled with its first 80 characters")
    func startsConversation() async throws {
        let engine = MockChatEngine()
        let store = SampleChatStore(conversations: [], engine: engine)
        let text = String(repeating: "a", count: 100)
        let id = try (store.send("  \(text)\n", to: nil, project: orders, origin: .tickets, attachments: [ord142], files: [], reader: reader()))
        let conversation = try #require(store.conversation(id))
        #expect(conversation.title == String(repeating: "a", count: 80))
        #expect(conversation.projectID == "ORD")
        #expect(conversation.origin == .tickets)
        #expect(conversation.turns.count == 1)
        #expect(conversation.turns[0].author == .user)
        #expect(conversation.turns[0].attachments == [ord142])
        #expect((store.activity(id) != nil))

        await store.repliesArrived()
        let replied = try #require(store.conversation(id))
        #expect(replied.turns.count == 2)
        #expect(replied.turns[1].author == .claude)
        #expect(replied.turns[1].isSample == false)
        #expect(!(store.activity(id) != nil))
        #expect(engine.messages.map(\.text) == [text])
        #expect(engine.messages.first?.attachments == [ord142])
    }

    @Test("A sample engine's reply is marked as a sample")
    func sampleReply() async {
        let engine = MockChatEngine()
        engine.repliesAreSamples = true
        let store = SampleChatStore(conversations: [], engine: engine)
        let id = try? store.send("Hello", to: nil, project: orders, origin: nil, attachments: [], files: [], reader: reader())
        await store.repliesArrived()
        #expect(store.conversation(id)?.turns.last?.isSample == true)
    }

    @Test("A later message goes to the same conversation")
    func laterMessage() async {
        let store = SampleChatStore(conversations: [conversation("a", minutesAgo: 10)], engine: MockChatEngine())
        let id = try? store.send("Again", to: "a", project: orders, origin: nil, attachments: [], files: [], reader: reader())
        #expect(id == "a")
        #expect(store.conversations.count == 1)
        await store.repliesArrived()
        #expect(store.conversation("a")?.turns.count == 3)
    }

    @Test("An empty or blank message isn't sent")
    func blankMessage() {
        let engine = MockChatEngine()
        let store = SampleChatStore(conversations: [], engine: engine)
        #expect((try? store.send(" \n ", to: nil, project: orders, origin: nil, attachments: [], files: [], reader: reader())) == nil)
        #expect(store.conversations.isEmpty)
    }

    @Test("Conversations of a set of projects, the latest first")
    func latestFirst() {
        let store = SampleChatStore(conversations: [
            conversation("old", minutesAgo: 60), conversation("new", minutesAgo: 1), conversation("other", project: "PAY", minutesAgo: 0),
        ], engine: MockChatEngine())
        #expect(store.conversations(of: ["ORD"]).map(\.id) == ["new", "old"])
        #expect(store.conversations(of: ["ORD", "PAY"]).map(\.id) == ["other", "new", "old"])
    }

    @Test("A decision answers the approval it names, and only that one")
    func decide() {
        let first = ChatApproval.comment(id: "first", on: ord142, preview: "One")
        let second = ChatApproval.comment(id: "second", on: ord142, preview: "Two")
        let turn = ChatTurn(id: "a.1", author: .claude, date: .now, blocks: [ChatBlock(.approval(first)), ChatBlock(.approval(second))])
        let store = SampleChatStore(conversations: [conversation("a", minutesAgo: 1, turns: [turn])], engine: MockChatEngine())
        store.decide("second", in: "a", allow: false)
        let decisions = store.conversation("a")!.turns[0].blocks.compactMap { block -> ChatApproval.Decision?? in
            if case .approval(let approval) = block.content { return approval.decision }
            return nil
        }
        #expect(decisions == [nil, .declined])
    }
}

// MARK: - Sample engine

@Suite("Sample engine")
struct SampleChatEngineTests {
    @Test("It finds tickets of known projects, requests and runs, in that order")
    func mentions() {
        let found = SampleChatEngine.mentions(in: "Is Run #1288 enough for ORD-142 and req-8f3a? Not XYZ-1.", project: orders)
        #expect(found.map(\.focus) == ["ORD-142", "request:req-8f3a", "1288"])
        #expect(found.map(\.tool) == [.tickets, .serviceMap, .builds])
        #expect(found[2].title == "Run 1288")
    }

    @Test("A ticket belongs to the project its prefix names")
    func ticketProject() {
        let found = SampleChatEngine.mentions(in: "See PAY-12.", project: orders)
        #expect(found.first?.projectID == "PAY")
    }

    @Test("An item that is attached and named is read once, as attached")
    func attachedAndNamed() {
        let onScreen = ChatReference(
            tool: .serviceMap, projectID: "ORD", focus: "request:req-8f3a", title: "req-8f3a", environment: "Staging"
        )
        let references = SampleChatEngine.references(
            for: "Why did req-8f3a fail? And ORD-142, ORD-142?", attachments: [onScreen, ord142], project: orders
        )
        #expect(references == [onScreen, ord142])
    }

    @Test("It reads each item through its tool and skips what the tool can't find")
    func reads() async {
        let engine = SampleChatEngine(delay: .zero)
        let reading = ToolReading(action: "Read ticket ORD-142", detail: "Retry storm")
        let blocks = await engine.reply(to: "And run 9999?", attachments: [ord142], project: orders, reader: reader(["ORD-142": reading]))
        #expect(blocks.count == 2)
        #expect(blocks[0].content == .toolCall(ord142, reading))
        guard case .text(let text) = blocks[1].content else {
            Issue.record("The reply ends with text")
            return
        }
        #expect(text.contains("Above is what I read"))
    }

    @Test("With nothing read, it says how to point at an item")
    func nothingRead() async {
        let blocks = await SampleChatEngine(delay: .zero).reply(to: "Hello", attachments: [], project: orders, reader: reader())
        #expect(blocks.count == 1)
        guard case .text(let text) = blocks[0].content else {
            Issue.record("The reply is text")
            return
        }
        #expect(text.contains("Attach an item"))
    }
}

// MARK: - Panel

@Suite("Chat panel")
struct ChatPanelModelTests {
    private func model(_ engine: MockChatEngine = MockChatEngine()) -> (ChatPanelModel, SampleChatStore) {
        let store = SampleChatStore(conversations: [], engine: engine)
        return (ChatPanelModel(chats: store), store)
    }

    @Test("The tool's selection is attached until the user takes it off, and comes back with a new selection")
    func attachment() {
        let (model, _) = model()
        #expect(model.attachment(for: ord142) == ord142)
        #expect(model.attachment(for: nil) == nil)
        model.leaveOut(ord142)
        #expect(model.attachment(for: ord142) == nil)
        #expect(model.attachment(for: run1288) == run1288)
        model.attach()
        #expect(model.attachment(for: ord142) == ord142)
        model.leaveOut(ord142)
        model.subjectChanged()
        #expect(model.attachment(for: ord142) == ord142)
    }

    @Test("The first message starts a conversation from the tool, with the attachment, and clears the draft")
    func firstMessage() async throws {
        let engine = MockChatEngine()
        let (model, store) = model(engine)
        model.draft = "What's left?"
        await model.sendDraft(project: orders, origin: .tickets, subject: ord142, reader: reader())
        let id = try #require(model.conversationID)
        #expect(model.draft.isEmpty)
        #expect(store.conversation(id)?.origin == .tickets)
        #expect(store.conversation(id)?.turns.first?.attachments == [ord142])
        #expect(model.isResponding)
        #expect(model.canStartNewChat)
        await store.repliesArrived()
        #expect(!model.isResponding)

        model.leaveOut(ord142)
        model.draft = "And without it?"
        await model.sendDraft(project: orders, origin: .tickets, subject: ord142, reader: reader())
        #expect(model.conversationID == id)
        #expect(store.conversation(id)?.turns[2].attachments == [])
        #expect(store.conversations.count == 1)
    }

    @Test("A suggestion sends at once and keeps the draft")
    func suggestion() async {
        let (model, store) = model()
        model.draft = "Half a thought"
        await model.send("Summarize ORD-142", project: orders, origin: .tickets, subject: ord142, reader: reader())
        #expect(model.draft == "Half a thought")
        #expect(store.conversation(model.conversationID)?.turns.first?.attachments == [ord142])
    }

    @Test("New Chat leaves the conversation, the draft and the left-out subject")
    func newChat() {
        let (model, _) = model()
        model.conversationID = "chat-checkout"
        model.draft = "Why did run 1288 fail?"
        model.leaveOut(ord142)
        model.startNewChat()
        #expect(model.conversationID == nil)
        #expect(model.draft.isEmpty)
        #expect(model.leftOut == nil)
        #expect(!model.canStartNewChat)
    }

    @Test("Open in Chat Window opens the project's Chat window on the open conversation")
    func chatWindowRoute() {
        let (model, _) = model()
        #expect(model.chatWindowRoute(for: orders) == .tool(.chat, project: "ORD", focus: nil))
        model.conversationID = "chat-checkout"
        #expect(model.chatWindowRoute(for: orders) == .tool(.chat, project: "ORD", focus: "chat-checkout"))
    }

    @Test("Suggestions come from the attached item's tool, then general ones, then the project's")
    func suggestions() {
        let (model, _) = model()
        let failed = ToolReading(action: "Read run 1288", detail: "Failed", suggestions: ["Why did run 1288 fail?"])
        #expect(model.suggestions(for: run1288, reader: reader(["1288": failed])) == ["Why did run 1288 fail?"])
        #expect(model.suggestions(for: run1288, reader: reader()) == ["What changed in run 1288?", "Summarize run 1288"])
        #expect(model.suggestions(for: nil, reader: reader()) == ChatSuggestion.project)
        model.leaveOut(run1288)
        #expect(model.suggestions(for: run1288, reader: reader(["1288": failed])) == ChatSuggestion.project)
    }

    @Test("A decision goes to the open conversation")
    func decide() {
        let approval = ChatApproval.comment(id: "a.comment", on: ord142, preview: "Seen again")
        let turn = ChatTurn(id: "a.1", author: .claude, date: .now, blocks: [ChatBlock(.approval(approval))])
        let store = SampleChatStore(conversations: [conversation("a", minutesAgo: 1, turns: [turn])], engine: MockChatEngine())
        let model = ChatPanelModel(chats: store)
        model.decide("a.comment", allow: true)
        model.conversationID = "a"
        model.decide("a.comment", allow: true)
        guard case .approval(let answered) = store.conversation("a")?.turns[0].blocks[0].content else {
            Issue.record("The block is an approval")
            return
        }
        #expect(answered.decision == .allowed)
    }
}

// MARK: - Window

@Suite("Chat window")
struct ChatWindowModelTests {
    private let store = SampleChatStore(conversations: [
        conversation("ord-old", minutesAgo: 60), conversation("ord-new", minutesAgo: 5),
        conversation("pay", project: "PAY", minutesAgo: 1), conversation("shop", project: "SHOP", minutesAgo: 30),
    ], engine: MockChatEngine())

    @Test("Without a focus it selects the latest conversation, and doesn't open its page")
    func latest() {
        let model = ChatWindowModel(project: orders, focus: nil, store: store)
        #expect(model.selection == "ord-new")
        #expect(!model.opensSelection)
    }

    @Test("A focus selects its conversation and opens its page")
    func focus() {
        let model = ChatWindowModel(project: orders, focus: "ord-old", store: store)
        #expect(model.selection == "ord-old")
        #expect(model.opensSelection)
    }

    @Test("A focus the list doesn't have falls back to the latest conversation")
    func unknownFocus() {
        let model = ChatWindowModel(project: orders, focus: "pay", store: store)
        #expect(model.selection == "ord-new")
        #expect(!model.opensSelection)
    }

    @Test("A route's focus selects its conversation again after the user picked another")
    func focusRequest() {
        let model = ChatWindowModel(project: orders, focus: "ord-old", store: store)
        model.selection = "ord-new"
        model.select(focus: "ord-old")
        #expect(model.selection == "ord-old")
        model.select(focus: "pay")
        #expect(model.selection == "ord-old")
    }

    @Test("A parent lists its sub projects' conversations, grouped in tree order")
    func grouped() {
        let shop = ChatWindowModel(project: Project.sample("SHOP")!, focus: nil, store: store)
        #expect(shop.isGrouped)
        #expect(shop.sections.map(\.project.id) == ["SHOP", "ORD", "PAY"])
        #expect(shop.selection == "pay")
        let orders = ChatWindowModel(project: orders, focus: nil, store: store)
        #expect(!orders.isGrouped)
        #expect(orders.sections.map(\.conversations).map { $0.map(\.id) } == [["ord-new", "ord-old"]])
    }

    @Test("A project without conversations shows the new chat")
    func noChats() {
        let model = ChatWindowModel(project: Project.sample("TLS")!, focus: nil, store: store)
        #expect(model.hasNoConversations)
        #expect(model.selection == nil)
        #expect(model.conversation == nil)
        #expect(model.references.isEmpty)
    }

    @Test("New Chat clears the selection and the draft, or opens the new chat as a page")
    func newChat() {
        let model = ChatWindowModel(project: orders, focus: nil, store: store)
        model.draft = "Draft"
        model.startNewChat(asPage: false)
        #expect(model.selection == nil)
        #expect(model.draft.isEmpty)
        model.startNewChat(asPage: true)
        #expect(model.selection == ChatWindowModel.newChatID)
        #expect(model.conversation == nil)
    }

    @Test("Sending from a new chat's page starts a conversation without an origin, and shows it")
    func sendFromNewChat() async throws {
        let store = SampleChatStore(conversations: [], engine: MockChatEngine())
        let model = ChatWindowModel(project: orders, focus: nil, store: store)
        model.startNewChat(asPage: true)
        model.draft = "What changed?"
        await model.sendDraft(reader: reader())
        let id = try #require(model.selection)
        #expect(id != ChatWindowModel.newChatID)
        #expect(store.conversation(id)?.origin == nil)
        #expect(store.conversation(id)?.turns.first?.attachments == [])
        #expect(model.draft.isEmpty)
        #expect(model.isResponding)
    }

    @Test("A suggestion keeps the draft")
    func suggestion() async {
        let model = ChatWindowModel(project: orders, focus: nil, store: SampleChatStore(conversations: [], engine: MockChatEngine()))
        model.draft = "Half a thought"
        await model.send("What changed this week?", reader: reader())
        #expect(model.draft == "Half a thought")
        #expect(model.conversation?.title == "What changed this week?")
    }
}

// MARK: - Wording and identifiers

@Suite("Chat wording")
struct ChatWordingTests {
    @Test("An approval asks in a whole sentence")
    func approvalSentence() {
        let approval = ChatApproval.comment(id: "a", on: ord142, preview: "")
        #expect(approval.request == "Claude wants to comment on ORD-142")
    }

    @Test("General suggestions name a run in lowercase and spell Summarize in American English")
    func generalSuggestions() {
        #expect(ChatSuggestion.general(about: run1288) == ["What changed in run 1288?", "Summarize run 1288"])
        #expect(ChatSuggestion.general(about: ord142).contains("Summarize ORD-142"))
        let release = ChatReference(tool: .builds, projectID: "ORD", focus: "release:v1.4.0", title: "Release v1.4.0")
        #expect(ChatSuggestion.general(about: release) == ["What changed in release v1.4.0?", "Summarize release v1.4.0"])
        let request = ChatReference(tool: .serviceMap, projectID: "ORD", focus: "request:req-8f3a", title: "req-8f3a")
        #expect(ChatSuggestion.general(about: request).allSatisfy { $0.contains("req-8f3a") })
        let dashboard = ChatReference(tool: .dashboard, projectID: "ORD", focus: "", title: "Orders")
        #expect(ChatSuggestion.general(about: dashboard) == ChatSuggestion.project)
    }

    @Test("Each suggestion has its own identifier, qualified by its words")
    func suggestionIdentifiers() {
        #expect(ChatSuggestion.identifier(for: "What's left before ORD-142 can be closed?") == "chat.suggestion.whats-left-before-ord-142-can-be-closed")
        let all = ChatSuggestion.project + ChatSuggestion.general(about: ord142) + ChatSuggestion.general(about: run1288)
        #expect(Set(all.map(ChatSuggestion.identifier(for:))).count == all.count)
    }

    @Test("A conversation lists what it attached or read once, in the order it came up")
    func references() {
        let turns = [
            ChatTurn(id: "a.1", author: .user, date: .now, attachments: [ord142], blocks: [ChatBlock(.text("Hi"))]),
            ChatTurn(id: "a.2", author: .claude, date: .now, blocks: [
                ChatBlock(.toolCall(ord142, ToolReading(action: "Read ticket ORD-142", detail: ""))),
                ChatBlock(.toolCall(run1288, ToolReading(action: "Read run 1288", detail: ""))),
            ]),
        ]
        #expect(conversation("a", minutesAgo: 0, turns: turns).references == [ord142, run1288])
    }

    @Test("The sample conversations have unique turn and approval ids")
    func sampleIDs() {
        let turns = ChatConversation.samples.flatMap(\.turns)
        #expect(Set(turns.map(\.id)).count == turns.count)
    }
}

/// docs/ui/chat.md › Drafts.
@MainActor
@Suite("Drafts")
struct ChatDraftsTests {
    private let orders = Project.sample("ORD")!

    @Test("Each chat keeps its own draft, shared by the views that show it; a new chat's stays in its view")
    func perChat() {
        let store = SampleChatStore(conversations: ChatConversation.samples, engine: MockChatEngine())
        let ids = store.conversations(of: ["ORD", "PAY"]).map(\.id)
        let window = ChatWindowModel(project: orders, focus: ids[0], store: store)
        let panel = ChatPanelModel(chats: store)
        window.draft = "About the first"
        window.files = [URL(fileURLWithPath: "/tmp/a.log")]
        panel.conversationID = ids[0]
        #expect(panel.draft == "About the first" && panel.files.count == 1, "Another view of the chat shows its draft")
        window.selection = ids[1]
        #expect(window.draft.isEmpty && window.files.isEmpty)
        window.draft = "About the second"
        window.selection = ids[0]
        #expect(window.draft == "About the first")
        window.startNewChat(asPage: false)
        #expect(window.draft.isEmpty)
        window.draft = "A new one"
        #expect(panel.draft == "About the first")
        window.selection = ids[1]
        #expect(window.draft == "About the second")
    }

    @Test("The panel's pop-up shows another chat of the project with its draft; picking the shown one changes nothing")
    func picker() {
        let store = SampleChatStore(conversations: ChatConversation.samples, engine: MockChatEngine())
        let ids = store.conversations(of: ["ORD"]).map(\.id)
        let panel = ChatPanelModel(chats: store)
        panel.conversationID = ids[0]
        panel.failure = "Not sent"
        panel.show(ids[0])
        #expect(panel.failure == "Not sent")
        store.drafts.setText("Kept", of: ids[1])
        panel.show(ids[1])
        #expect(panel.conversationID == ids[1] && panel.draft == "Kept" && panel.failure == nil)
        panel.show(nil)
        #expect(panel.conversationID == ids[1])
    }
}

/// docs/ui/chat.md › Claude CLI line.
@MainActor
@Suite("Claude CLI line")
struct ClaudeCLILineTests {
    @Test("The line shows while the CLI is checked or can't be used, never without a CLI or once it is found")
    func shows() {
        #expect(!ClaudeCLILine.shows(nil))
        #expect(ClaudeCLILine.shows(.checking))
        #expect(ClaudeCLILine.shows(ClaudeStatus(error: "Claude CLI not found.")))
        #expect(!ClaudeCLILine.shows(ClaudeStatus(path: "/usr/local/bin/claude", version: "2.1.322")))
        #expect(SampleChatStore.transient().cliStatus == nil)
    }

    @Test("Settings' tabs are stored by name, under one key")
    func settingsPanes() {
        #expect(SettingsPane.allCases.map(\.rawValue) == ["general", "projects", "mcp", "machines", "chat", "notifications", "updates"])
        #expect(SettingsPane.storageKey == "settings.pane")
    }
}

/// docs/ui/chat.md › Files: the CLI's other tools.
@MainActor
@Suite("CLI tool wording")
struct CLIToolTextTests {
    @Test("Shell, web and agent calls read as V2 named them, with their detail; another tool has no wording of its own")
    func calls() {
        let bash = CLIToolText.call("Bash", input: ["command": "swift test\n--parallel", "description": "Run the tests"])
        #expect(bash?.action == "Ran Run the tests" && bash?.detail == "swift test\n--parallel")
        #expect(CLIToolText.call("Bash", input: ["command": "sleep 5", "run_in_background": true])?.action == "Started in the background: sleep 5")
        #expect(CLIToolText.call("WebFetch", input: ["url": "https://developer.apple.com/documentation"])?.action == "Fetched developer.apple.com")
        #expect(CLIToolText.call("WebSearch", input: ["query": "swift testing"])?.action == "Searched the web for “swift testing”")
        #expect(CLIToolText.call("Agent", input: ["description": "Probe", "prompt": "Look"])?.action == "Ran an agent: Probe")
        #expect(CLIToolText.call("Mystery", input: [:]) == nil)
        #expect(CLIToolText.request("Bash", input: [:]) == "Claude wants to run a command")
        #expect(CLIToolText.request("WebFetch", input: ["url": "https://example.com/a"]) == "Claude wants to fetch example.com")
        #expect(CLIToolText.request("Mystery", input: [:]) == nil)
        #expect(SampleChatStore.transient().queuesMessages == false)
    }
}

/// docs/ui/chat.md › Agents.
@MainActor
@Suite("Agent rows")
struct AgentRowsTests {
    @Test("A row's tag names its chat and itself; a chat's id isn't a row; the Chat window shows a selected row's view")
    func tags() throws {
        let store = SampleChatStore.withAgents()
        let rows = store.agentRows(of: "chat-checkout")
        #expect(rows.map(\.kind) == [.workflow, .workflowAgent, .workflowAgent, .subagent])
        #expect(rows[0].tag == "workflow|chat-checkout|wf1" && rows[1].tag == "agent|chat-checkout|a1")
        let parsed = try #require(ChatAgentRow.parse("agent|chat-checkout|a1"))
        #expect(!parsed.isWorkflow && parsed.chatID == "chat-checkout" && parsed.id == "a1")
        #expect(ChatAgentRow.parse("chat-checkout") == nil)
        #expect(rows[3].canResume && !rows[1].canResume && rows[1].workflowRuns)
        let model = ChatWindowModel(project: Project.sample("ORD")!, focus: "chat-checkout", store: store)
        model.select(rows[1])
        #expect(model.selectedAgent == rows[1] && model.conversation == nil)
        #expect(store.agentConversation(rows[1]).turns.count == 2)
    }
}

/// The Chat window drew forever in 1.0.36 and 1.0.37: the composer's field wrote back the draft it showed, and
/// each write notified the views again.
@MainActor
@Suite("Drafts written again")
struct DraftRewriteTests {
    @Test("Writing a chat's draft as it is notifies no view")
    func sameValue() {
        let store = SampleChatStore.transient()
        let id = store.conversations(of: ["ORD"]).first!.id
        let model = ChatWindowModel(project: Project.sample("ORD")!, focus: id, store: store)
        model.draft = "Half a thought"
        let notified = Mutex(false)
        withObservationTracking { _ = model.draft; _ = model.files } onChange: { notified.withLock { $0 = true } }
        model.draft = "Half a thought"
        model.files = []
        store.drafts.setText("Half a thought", of: id)
        #expect(!notified.withLock { $0 })
        model.draft = "More"
        #expect(notified.withLock { $0 })
    }
}
