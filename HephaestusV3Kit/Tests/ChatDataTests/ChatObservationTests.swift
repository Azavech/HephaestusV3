import FileStorage
import Foundation
import Observation
import Testing
@testable import ChatData

/// Whether an observation was told of a change.
final class ChangeFlag: @unchecked Sendable {
    private(set) var raised = false

    func raise() { raised = true }
}

/// docs/architecture.md › ChatData: what a chat at work makes the windows and the session do again.
@Suite("Chat changes, observed by chat")
@MainActor
struct ChatObservationTests {
    @Test("A view reading one chat's value is told of that chat's changes only, an in-place change included")
    func perChat() {
        let values = PerChat<[Int]>()
        values["A"] = [1]
        values["B"] = [2]
        let revision = values.revision(of: "A")
        let told = ChangeFlag()
        withObservationTracking { _ = values["A"] } onChange: { told.raise() }
        values["B"] = [3]
        values.modify("B") { $0?.append(4) }
        #expect(!told.raised, "Another chat's changes")
        #expect(values.revision(of: "A") == revision)
        values.modify("A") { $0?.append(5) }
        #expect(told.raised)
        #expect(values["A"] == [1, 5] && values["B"] == [3, 4])
        #expect(values.revision(of: "A") == revision + 1)

        let toldOfRevision = ChangeFlag()
        withObservationTracking { _ = values.revision(of: "B") } onChange: { toldOfRevision.raise() }
        values["B"] = nil
        #expect(toldOfRevision.raised, "Reading the revision observes the value")
    }

    @Test("A transcript's line, a chat's folder of agents and the session's own write of a chat's file don't read the chats again; another's write does")
    func fileEvents() async throws {
        let world = try await ChatWorld()
        defer { Task { await world.close() } }
        let id = try await world.session.send("Run it", references: [], to: nil, projectID: "ORD")
        let chats = world.repo.appendingPathComponent(".hephaestus/chats")
        let file = chats.appendingPathComponent("\(id).yml").path
        let session = world.session
        #expect(!session.changesChats(FileEvent(path: chats.appendingPathComponent("\(id).jsonl").path, kind: .modified)))
        #expect(!session.changesChats(FileEvent(path: chats.appendingPathComponent("\(id)/agents.jsonl").path, kind: .modified)))
        #expect(!session.changesChats(FileEvent(path: file, kind: .modified)), "The session wrote it")
        #expect(session.changesChats(FileEvent(path: chats.path, kind: .created)))
        #expect(session.changesChats(FileEvent(path: world.repo.path, kind: .mustRescan)))
        #expect(session.changesChats(FileEvent(path: chats.appendingPathComponent("\(UUID().uuidString).yml").path, kind: .removed)),
                "A chat's file removed by someone else")

        let edited = try String(contentsOfFile: file, encoding: .utf8) + "# Edited elsewhere\n"
        try edited.write(toFile: file, atomically: true, encoding: .utf8)
        #expect(session.changesChats(FileEvent(path: file, kind: .modified)))

        let cli = try #require(world.launcher.chats.first)
        cli.finish(.exited(0))
        try await world.until { session.runs[id] == nil }
    }
}
