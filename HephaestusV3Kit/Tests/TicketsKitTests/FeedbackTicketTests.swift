import Foundation
import Testing
import ToolsFoundation
@testable import TicketsKit

/// Records the changes asked for; creates `FB-1`, or fails the creation or the attachments when told to.
@MainActor
final class RecordingTicketStore: TicketStore {
    var performed: [TicketChangeRequest] = []
    var createFails: String?
    var attachFails: String?

    func tickets(of projects: Set<Project.ID>) -> [Ticket] { [] }
    func bundles(of projects: Set<Project.ID>) -> [TicketBundle] { [] }
    func ticket(_ id: Ticket.ID) -> Ticket? { nil }

    func perform(_ change: TicketChangeRequest) async throws(TicketStoreError) -> String? {
        performed.append(change)
        switch change {
        case .create:
            if let createFails { throw TicketStoreError(message: createFails) }
            return "FB-1"
        case .addAttachments:
            if let attachFails { throw TicketStoreError(message: attachFails) }
            return nil
        default:
            return nil
        }
    }
}

/// The Send Feedback sheet's model: a regular ticket, then its files (docs/ui/tickets.md › Feedback).
@MainActor
@Suite("Feedback ticket")
struct FeedbackTicketTests {
    private let context = "App: Hephaestus V3 1.0.18 (40) · macOS 27.2 · Window: Tickets · Project: Orders (ORD) · Item: ORD-142"
    private let screenshot = URL(fileURLWithPath: "/tmp/feedback/screenshot.png")

    private func model(_ store: RecordingTicketStore, screenshot: URL? = URL(fileURLWithPath: "/tmp/feedback/screenshot.png")) -> FeedbackTicketModel {
        FeedbackTicketModel(project: Project.sample("ORD")!, screenshot: screenshot, context: context, store: store)
    }

    @Test("Send creates New Ticket's ticket in the feedback project, the context after the description, then attaches the screenshot and the files in one request")
    func send() async {
        let store = RecordingTicketStore()
        let model = model(store)
        model.draft.title = "The ladybug hides"
        model.draft.details = "  It sits under the divider.\n"
        let log = URL(fileURLWithPath: "/tmp/feedback/app.log")
        model.add([log])
        #expect(await model.send() == "FB-1")
        var expected = NewTicketDraft(projectID: "ORD")
        expected.title = "The ladybug hides"
        expected.details = "It sits under the divider.\n\n" + context
        #expect(store.performed == [.create(expected), .addAttachments("FB-1", [screenshot, log])])
        #expect(model.message == nil)
    }

    @Test("A screenshot left out, or none, isn't attached; with nothing to attach, only the ticket is made")
    func withoutScreenshot() async {
        let store = RecordingTicketStore()
        let model = model(store)
        model.draft.title = "Feedback"
        model.includesScreenshot = false
        #expect(await model.send() == "FB-1")
        #expect(store.performed.count == 1)
        let uncaptured = RecordingTicketStore()
        let other = self.model(uncaptured, screenshot: nil)
        other.draft.title = "Feedback"
        #expect(await other.send() == "FB-1")
        #expect(uncaptured.performed.count == 1)
        if case .create(let draft) = uncaptured.performed.first {
            #expect(draft.details == context)
        } else {
            Issue.record("No ticket was created")
        }
    }

    @Test("A blank title sends nothing")
    func blankTitle() async {
        let store = RecordingTicketStore()
        let model = model(store)
        model.draft.title = "   "
        #expect(!model.canSend)
        #expect(await model.send() == nil)
        #expect(store.performed.isEmpty)
    }

    @Test("A ticket that can't be created keeps the sheet, with the reason")
    func createFails() async {
        let store = RecordingTicketStore()
        store.createFails = "The project's tickets can't be written."
        let model = model(store)
        model.draft.title = "Feedback"
        #expect(await model.send() == nil)
        #expect(model.message == "The project's tickets can't be written.")
        #expect(model.canSend)
        #expect(store.performed.count == 1)
    }

    @Test("Files that can't be attached leave the created ticket, which the sheet offers to show, and no second Send")
    func attachFails() async {
        let store = RecordingTicketStore()
        store.attachFails = "The attachments of one request exceed 20 MB."
        let model = model(store)
        model.draft.title = "Feedback"
        #expect(await model.send() == nil)
        #expect(model.createdWithoutFiles == "FB-1")
        #expect(model.message == "FB-1 was created without its files: The attachments of one request exceed 20 MB.")
        #expect(!model.canSend)
    }

    @Test("Files are added once each, in order; a folder or a file over 20 MB adds nothing from that drop")
    func files() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FeedbackTicketTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let small = folder.appendingPathComponent("app.log")
        try Data("log".utf8).write(to: small)
        let other = folder.appendingPathComponent("trace.json")
        try Data("{}".utf8).write(to: other)
        let large = folder.appendingPathComponent("dump.bin")
        FileManager.default.createFile(atPath: large.path, contents: nil)
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(FeedbackTicketModel.attachmentLimit + 1))
        try handle.close()

        let model = model(RecordingTicketStore())
        model.add([small, other, small])
        #expect(model.files == [small, other])
        model.add([large, small])
        #expect(model.message == "dump.bin is larger than 20 MB.")
        #expect(model.files == [small, other])
        model.add([folder])
        #expect(model.message == "Folders cannot be attached.")
        model.remove(small)
        #expect(model.files == [other])
    }
}
