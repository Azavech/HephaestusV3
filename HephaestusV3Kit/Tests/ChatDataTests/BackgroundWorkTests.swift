import Foundation
import MCPKit
import Testing
@testable import ChatData

/// docs/data.md › Background work, on V2's capture `stream-background-bash.jsonl`: Claude runs `sleep 15; echo
/// bg-done` in the background, ends its turn, and reports when the command has ended.
@Suite("Background work")
@MainActor
struct BackgroundWorkTests {
    @Test("A background task keeps the process at work after its turn; the CLI's own turn reports it, then it ends")
    func backgroundBash() async throws {
        let world = try await ChatWorld()
        defer { Task { await world.close() } }
        let id = try await world.session.send("Run it in the background", references: [], to: nil, projectID: "ORD")
        let cli = try #require(world.launcher.chats.first)
        let lines = try Fixture.lines("stream-background-bash.jsonl")
        // Lines 1 to 18: the turn starts, then the task.
        cli.feed(Array(lines[0..<18]))
        try await world.until { world.session.backgroundWork.contains(id) }
        #expect(world.session.state(of: id) == .running)
        // 19 to 29: the turn ends; the task still runs.
        cli.feed(Array(lines[18..<29]))
        try await world.until { world.session.state(of: id) == .idle }
        #expect(world.session.backgroundWork.contains(id))
        #expect(world.session.runs[id]?.idleTimer == nil, "No idle timer while work runs")
        // 30 to 33: the task ends between turns; the CLI owes a turn, so the work still counts.
        cli.feed(Array(lines[29..<33]))
        try await world.until { world.session.runs[id]?.backgroundTasks.isEmpty == true }
        #expect(world.session.runs[id]?.notificationPending == true && world.session.backgroundWork.contains(id))
        // 34: the CLI's own turn opens: running, the work over.
        cli.feed(Array(lines[33..<34]))
        try await world.until { world.session.state(of: id) == .running }
        #expect(!world.session.backgroundWork.contains(id))
        // 35 to 43: Claude reports, and the chat is idle again, its idle timer set.
        cli.feed(Array(lines[34...]))
        try await world.until { world.session.state(of: id) == .idle }
        #expect(world.session.runs[id]?.idleTimer != nil)
        cli.finish(.exited(0))
        try await world.until { world.session.runs[id] == nil }
        #expect(!world.session.backgroundWork.contains(id))
    }

    @Test("The lines map to the running tasks and the ended task")
    func mapping() {
        var mapper = StreamMapper(effort: .high, now: { Date() })
        let changed = #"{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"bw1"},{"x":1}]}"#
        #expect(mapper.map(Data(changed.utf8)) == [.backgroundTasks(["bw1"])])
        #expect(mapper.map(Data(#"{"type":"system","subtype":"task_notification","task_id":"bw1"}"#.utf8)).first == .taskNotification(taskID: "bw1"))
    }
}
