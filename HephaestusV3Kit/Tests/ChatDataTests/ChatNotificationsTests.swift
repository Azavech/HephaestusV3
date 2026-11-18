import FileStorage
import Foundation
import MCPKit
import Testing
@testable import ChatData

/// docs/data.md › Chat events, docs/ui/chat.md › Notifications.
@Suite("Chat notifications")
@MainActor
struct ChatNotificationsTests {
    @Test("A summary is cleaned as V2 cleaned it: one line, no Summary: label, no quotes, cut at the last space before 150")
    func clean() {
        #expect(ChatEvent.cleanSummary("  Summary:  \"Claude fixed\n\nthe totals.\"  ") == "Claude fixed the totals.")
        #expect(ChatEvent.cleanSummary("«'Wants to run git push'»") == "Wants to run git push")
        #expect(ChatEvent.cleanSummary(" \n ") == nil)
        #expect(ChatEvent.cleanSummary("SUMMARY: \"\"") == nil)
        let long = String(repeating: "word ", count: 40)
        let cut = ChatEvent.cleanSummary(long)
        #expect(cut?.count == 149 && cut?.hasSuffix("word") == true)
        #expect(ChatEvent.cleanSummary(String(repeating: "a", count: 200))?.count == 150, "Without a space, cut at 150")
    }

    @Test("A turn that ends well reports finished, with the reply's first line and the reply to sum up")
    func finished() async throws {
        let world = try await ChatWorld()
        defer { Task { await world.close() } }
        var events: [ChatEvent] = []
        world.session.onEvent = { events.append($0) }
        let id = try await world.session.send("Run it", references: [], to: nil, projectID: "ORD")
        let cli = try #require(world.launcher.chats.first)
        cli.feed(try Fixture.lines("stream-bash-allowed.jsonl"))
        try await world.until { world.session.state(of: id) == .idle && !events.isEmpty }
        #expect(events.map(\.kind) == [.finished])
        let event = try #require(events.first)
        let reply = world.items(id).compactMap { if case .assistant(let text) = $0 { text.text } else { nil } }.last ?? ""
        #expect(event.chatID == id && event.projectID == "ORD" && event.title == world.session.chats[id]?.file.title)
        #expect(event.detail == reply.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) })
        #expect(event.summaryInput == "Claude's reply:\n" + reply)
        cli.finish(.exited(0))
    }

    @Test("A card that starts to wait reports needs you, with the request to sum up; the first state reports nothing")
    func needsYou() async throws {
        let world = try await ChatWorld()
        defer { Task { await world.close() } }
        var events: [ChatEvent] = []
        world.session.onEvent = { events.append($0) }
        let id = try await world.session.send("Comment", references: [], to: nil, projectID: "ORD")
        #expect(events.isEmpty, "A new chat's first state is not a change")
        let answer = Task { await world.session.requestApproval(id, tool: "add_comment", input: ["ticketID": "ORD-1", "text": "Done"]) }
        try await world.until { world.session.state(of: id) == .waitingPermission }
        #expect(events.map(\.kind) == [.needsYou])
        #expect(events.first?.detail == "Waiting for your permission")
        #expect(events.first?.summaryInput == #"Permission request:\#nTool: add_comment\#nInput: {"text":"Done","ticketID":"ORD-1"}"#)
        #expect(world.session.waitingChats == [id])
        world.session.answer(id, requestID: try #require(pendingRequest(world, id)), allow: true)
        _ = await answer.value
        #expect(world.session.waitingChats.isEmpty && world.session.runningChats == [id])
        world.launcher.chats.first?.finish(.exited(0))
    }

    @Test("A turn ended with Stop reports nothing")
    func stopped() async throws {
        let world = try await ChatWorld()
        defer { Task { await world.close() } }
        var events: [ChatEvent] = []
        world.session.onEvent = { events.append($0) }
        let id = try await world.session.send("Write it", references: [], to: nil, projectID: "ORD")
        let cli = try #require(world.launcher.chats.first)
        try await world.until { world.session.state(of: id) == .starting }
        world.session.stop(id)
        cli.feed(#"{"type":"result","subtype":"error_during_execution","is_error":true,"duration_ms":5,"errors":["[ede_diagnostic] x"]}"#)
        try await world.until { world.session.state(of: id) == .idle }
        #expect(events.isEmpty)
        cli.finish(.exited(0))
    }

    @Test("Without a reply, or when the skill fails, the summary is the fallback detail")
    func fallback() async throws {
        let world = try await ChatWorld()
        defer { Task { await world.close() } }
        let bare = ChatEvent(chatID: "C1", projectID: "ORD", title: "T", kind: .finished, detail: "Claude finished replying", summaryInput: nil)
        #expect(await world.session.summary(of: bare) == "Claude finished replying")
        var failing = bare
        failing.summaryInput = "Claude's reply:\nDone."
        failing.detail = "Done."
        #expect(await world.session.summary(of: failing) == "Done.", "The stand-in CLI fails")
    }

    @Test("A chat shown in the key window is known, and loses its notification when it starts to show there")
    func keyWindow() async throws {
        let world = try await ChatWorld()
        defer { Task { await world.close() } }
        var opened: [String] = []
        world.session.onOpen = { opened.append($0) }
        let view = UUID()
        world.session.showing("C1", inKeyWindow: false, view: view)
        #expect(!world.session.isInKeyWindow("C1") && opened.isEmpty)
        world.session.showing("C1", inKeyWindow: true, view: view)
        world.session.showing("C1", inKeyWindow: true, view: view)
        #expect(world.session.isInKeyWindow("C1") && opened == ["C1"], "Once, as it becomes key")
        world.session.showing(nil, inKeyWindow: false, view: view)
        #expect(!world.session.isInKeyWindow("C1"))
    }

    private func pendingRequest(_ world: ChatWorld, _ id: String) -> String? {
        world.items(id).lazy.compactMap { item -> String? in
            if case .permissionRequest(let request) = item, request.isPending { return request.requestID }
            return nil
        }.first
    }
}
