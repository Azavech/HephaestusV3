import ExternalTools
import FileStorage
import Foundation
import ProjectData
import Synchronization
import Testing
@testable import TicketData

/// Starts no process: every run fails.
private struct NoProcesses: ProcessRunning {
    func run(_ request: ProcessRequest, input: Data?, timeout: Duration?) async throws -> ProcessResult {
        ProcessResult(termination: .exited(1))
    }
}

/// A temporary world: a data folder, one project `HEPH` in `Repo`, and a folder standing for the Trash, all
/// deleted afterwards. Tests never touch the user's projects, data folder or Trash.
private final class World: Sendable {
    let root: URL
    let project: URL
    let trash: URL
    let projects: ProjectLibrary
    let library: TicketLibrary
    static let date = ISODate.date(from: "2026-11-14T10:00:00Z")!
    static let me = TicketActor.user(device: "Studio")
    static let claude = TicketActor.claude(chat: "external")

    init(extraProjectLines: String = "") async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("TicketDataTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        project = root.appendingPathComponent("Repo", isDirectory: true)
        trash = root.appendingPathComponent("Trash", isDirectory: true)
        let file = project.appendingPathComponent(".hephaestus/project.yml")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try Data("schema: 1\nid: HEPH\nname: Hephaestus\ncreated: 2026-10-31T09:30:00Z\n\(extraProjectLines)".utf8).write(to: file)
        let data = DataFolder(url: root.appendingPathComponent("Data", isDirectory: true))
        try data.createIfNeeded()
        try YAMLFile.write(RegistryFile(projects: [project.path]), to: data.registryFile)
        projects = ProjectLibrary(dataFolder: data, runner: NoProcesses(), now: { World.date })
        library = TicketLibrary(projects: projects, trash: .folder(trash), now: { World.date })
        _ = await library.sync(with: await projects.load())
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func url(_ relative: String) -> URL { project.appendingPathComponent(".hephaestus/" + relative) }

    func text(_ relative: String) throws -> String { try String(contentsOf: url(relative), encoding: .utf8) }

    func write(_ relative: String, _ text: String) throws {
        try FileManager.default.createDirectory(at: url(relative).deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url(relative))
    }

    func ticket(_ id: String) async -> LoadedTicket? { await library.snapshot.ticket(id) }

    @discardableResult
    func create(_ title: String, status: TicketFileStatus = .todo, links: [TicketLinkEntry] = [], files: [URL] = []) async throws -> String {
        try await library.create(.init(projectID: "HEPH", title: title, status: status, links: links, attachments: files), by: World.me).id
    }

    /// A file outside the project, to attach.
    func source(_ name: String, bytes: Int = 4) throws -> URL {
        let url = root.appendingPathComponent("Sources/\(name)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    var trashedNames: [String] {
        let items = (try? FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil)) ?? []
        return items.flatMap { (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) ?? [] }.sorted()
    }
}

/// The ticket error `body` throws, or nil.
private func failure(_ body: () async throws -> Void) async -> TicketError? {
    do {
        try await body()
        return nil
    } catch let error as TicketError {
        return error
    } catch {
        Issue.record(error)
        return nil
    }
}

@Suite("Ticket library")
struct TicketLibraryTests {
    // MARK: Creating

    @Test("Numbers come from the project's counter, skip existing files, and the counter is written first")
    func numbering() async throws {
        let world = try await World(extraProjectLines: "nextTicketNumber: 4\n")
        try world.write("ticket/HEPH-5.yml", "schema: 1\nid: HEPH-5\ntitle: Kept\ncreated: 2026-11-01T10:00:00Z\n")
        _ = await world.library.sync(with: await world.projects.load())
        #expect(try await world.create("First") == "HEPH-4")
        #expect(try await world.create("Second") == "HEPH-6")
        #expect(try world.text("project.yml").contains("nextTicketNumber: 7"))
        let ticket = try #require(await world.ticket("HEPH-4"))
        #expect(ticket.file.status == .todo)
        #expect(ticket.file.createdBy == .user)
        #expect(ticket.file.history == [HistoryEntry(kind: .created, date: World.date, to: "todo", author: .user, device: "Studio")])
        #expect(try world.text("ticket/HEPH-4.yml").contains("device: Studio"))
    }

    @Test("Without a title, the description's first plain line names the ticket; neither fails")
    func provisionalTitle() async throws {
        let world = try await World()
        let id = try await world.library.create(.init(projectID: "heph", description: "## Problem\n\n  Tabs close when I click  \nmore"),
                                                by: World.me).id
        #expect(await world.ticket(id)?.file.title == "Tabs close when I click")
        let error = await failure { _ = try await world.library.create(.init(projectID: "HEPH", description: " \n"), by: World.me) }
        #expect(error == .invalid("The description must not be empty."))
        let title = await failure { _ = try await world.library.create(.init(projectID: "HEPH", title: "a\nb"), by: World.me) }
        #expect(title == .invalid("Title must be 1 to 200 characters on one line."))
        let missing = await failure { _ = try await world.library.create(.init(projectID: "NOPE", title: "x"), by: World.me) }
        #expect(missing == .notFound("Project NOPE not found."))
        #expect(TicketRules.provisionalTitle(from: "# Heading\n\n## Other\n") == "Untitled Ticket")
    }

    @Test("A ticket created without a title is told to the untitled handler, whoever creates it; one with a title isn't")
    func untitledHandler() async throws {
        let world = try await World()
        let told = Mutex<[TicketLibrary.UntitledTicket]>([])
        await world.library.onUntitled { ticket in told.withLock { $0.append(ticket) } }
        let id = try await world.library.create(.init(projectID: "HEPH", description: "Tabs close when I click\n\nApp: Hephaestus V3"),
                                                by: World.me).id
        try await world.create("Has a title")
        let claude = try await world.library.create(.init(projectID: "HEPH", description: "From a chat"), by: World.claude).id
        #expect(told.withLock { $0 } == [
            TicketLibrary.UntitledTicket(id: id, projectID: "HEPH", provisionalTitle: "Tabs close when I click", description: "Tabs close when I click\n\nApp: Hephaestus V3"),
            TicketLibrary.UntitledTicket(id: claude, projectID: "HEPH", provisionalTitle: "From a chat", description: "From a chat"),
        ])
    }

    @Test("A generated title replaces the provisional one, as the app on its own; one the user gave since stays")
    func generatedTitle() async throws {
        let world = try await World()
        let id = try await world.library.create(.init(projectID: "HEPH", description: "Tabs close when I click"), by: World.me).id
        #expect(try await world.library.setGeneratedTitle("Tabs close on click", of: id, replacing: "Tabs close when I click") != nil)
        let ticket = try #require(await world.ticket(id))
        #expect(ticket.file.title == "Tabs close on click")
        #expect(ticket.file.history.last == HistoryEntry(kind: .title, date: World.date, from: "Tabs close when I click", to: "Tabs close on click",
                                                         author: .automatic))
        // The user renamed it before the answer came: the generated title doesn't overwrite theirs.
        let other = try await world.library.create(.init(projectID: "HEPH", description: "Second"), by: World.me).id
        _ = try await world.library.update(other, .init(title: "Mine"), by: World.me)
        #expect(try await world.library.setGeneratedTitle("Generated", of: other, replacing: "Second") == nil)
        #expect(await world.ticket(other)?.file.title == "Mine")
    }

    @Test("A title from Claude's answer: its first line, without a heading's marks or quotes, cut to 200 characters")
    func titleFromAnswer() {
        #expect(TicketRules.title(fromAnswer: "\n  Tabs close on click  \nBecause…") == "Tabs close on click")
        #expect(TicketRules.title(fromAnswer: "## Tabs close on click") == "Tabs close on click")
        #expect(TicketRules.title(fromAnswer: "\"Tabs close on click\"") == "Tabs close on click")
        #expect(TicketRules.title(fromAnswer: "“Tabs close on click”") == "Tabs close on click")
        #expect(TicketRules.title(fromAnswer: String(repeating: "a", count: 250))?.count == 200)
        #expect(TicketRules.title(fromAnswer: " \n#\n\"\"") == nil)
        #expect(TicketRules.title(fromAnswer: "") == nil)
    }

    @Test("Claude's tickets take any description, start To Do and record the chat")
    func claudeCreates() async throws {
        let world = try await World()
        let id = try await world.library.create(.init(projectID: "HEPH", title: "Fix", description: "Tabs close.", status: .draft),
                                                by: World.claude).id
        let ticket = try #require(await world.ticket(id))
        #expect(ticket.file.status == .todo)
        #expect(ticket.file.createdBy == .claude)
        #expect(ticket.file.description == "Tabs close.")
        #expect(ticket.file.history.first?.chat == "external")
        _ = try await world.library.update(id, .init(description: "Tabs close on click."), by: World.claude)
        #expect(await world.ticket(id)?.file.description == "Tabs close on click.")
    }

    @Test("The user may create a draft (V3)")
    func draft() async throws {
        let world = try await World()
        let id = try await world.create("Idea", status: .draft)
        #expect(try world.text("ticket/\(id).yml").contains("status: draft"))
        let error = await failure { _ = try await world.library.create(.init(projectID: "HEPH", title: "x", status: .done), by: World.me) }
        #expect(error == .invalid("A new ticket is To Do or a draft."))
    }

    // MARK: Links

    @Test("Link rules 1 to 7, in order, with their messages")
    func linkRules() async throws {
        let world = try await World()
        let one = try await world.create("One")
        let two = try await world.create("Two", links: [.init(kind: .dependsOn, ticketID: "heph-1")])
        let three = try await world.create("Three", links: [.init(kind: .dependsOn, ticketID: two)])
        func update(_ id: String, _ links: [TicketLinkEntry]) async -> TicketError? {
            await failure { _ = try await world.library.update(id, .init(links: links), by: World.me) }
        }
        #expect(await update(one, [.init(kind: .related, ticketID: "nope")]) == .invalid("\"nope\" is not a valid ticket id."))
        #expect(await update(one, [.init(kind: .related, ticketID: "AB-1")]) == .invalid("AB-1 does not belong to project HEPH."))
        #expect(await update(one, [.init(kind: .related, ticketID: one)]) == .invalid("HEPH-1 cannot be linked to itself."))
        #expect(await update(three, [.init(kind: .related, ticketID: one), .init(kind: .dependsOn, ticketID: one)])
            == .invalid("HEPH-1 is listed more than once."))
        #expect(await update(one, [.init(kind: .related, ticketID: "HEPH-40")]) == .notFound("Ticket HEPH-40 not found."))
        #expect(await update(one, [.init(kind: .related, ticketID: two)]) == .invalid("HEPH-1 is already linked to HEPH-2."))
        #expect(await update(one, [.init(kind: .dependsOn, ticketID: three)]) == .invalid("HEPH-1 cannot depend on HEPH-3, which depends on HEPH-1."))
        let ticketOne = try #require(await world.ticket(one))
        #expect(ticketOne.inverseLinks == [.init(kind: .blocks, ticketID: two)])
        #expect(await world.ticket(two)?.file.links == [.init(kind: .dependsOn, ticketID: one)])
    }

    @Test("A change adds its history entries in order; the same values write nothing")
    func updateHistory() async throws {
        let world = try await World()
        let one = try await world.create("One")
        let two = try await world.create("Two")
        let three = try await world.create("Three", links: [.init(kind: .related, ticketID: one)])
        _ = try await world.library.update(three, .init(title: " Renamed ", description: "New", links: [.init(kind: .dependsOn, ticketID: two)]),
                                           by: World.me)
        let history = try #require(await world.ticket(three)).file.history
        #expect(history.map(\.kind) == [.created, .title, .description, .linkRemoved, .linkAdded])
        #expect(history[1].from == "Three" && history[1].to == "Renamed")
        #expect(history[3].to == "related HEPH-1" && history[4].to == "dependsOn HEPH-2")
        let before = try world.text("ticket/\(three).yml")
        _ = try await world.library.update(three, .init(title: "Renamed", description: "New"), by: World.me)
        #expect(try world.text("ticket/\(three).yml") == before)
        _ = try await world.library.update(three, .init(priority: .some(.high), labels: [" ui ", "", "ui", "api"]), by: World.me)
        let ticket = try #require(await world.ticket(three))
        #expect(ticket.file.priority == .high && ticket.file.labels == ["ui", "api"])
        #expect(ticket.file.history.count == 5)
    }

    // MARK: Status

    @Test("Claude never changes a done ticket or a draft; the same status adds nothing")
    func statusRules() async throws {
        let world = try await World()
        let id = try await world.create("One")
        _ = try await world.library.setStatus(id, to: .inProgress, by: World.claude)
        _ = try await world.library.setStatus(id, to: .inProgress, by: World.claude)
        #expect(await world.ticket(id)?.file.history.map(\.kind) == [.created, .status])
        #expect(await failure { _ = try await world.library.setStatus(id, to: .draft, by: World.claude) }
            == .forbidden("Only the user can make HEPH-1 a draft."))
        _ = try await world.library.setStatus(id, to: .done, by: World.claude)
        #expect(await failure { _ = try await world.library.setStatus(id, to: .done, by: World.claude) }
            == .forbidden("HEPH-1 is done; only the user can change its status."))
        _ = try await world.library.setStatus(id, to: .draft, by: World.me)
        #expect(await failure { _ = try await world.library.setStatus(id, to: .todo, by: World.claude) }
            == .forbidden("HEPH-1 is a draft; only the user can change its status."))
        let last = try #require(await world.ticket(id)?.file.history.last)
        #expect(last.from == "done" && last.to == "draft" && last.device == "Studio")
    }

    // MARK: Bundles

    @Test("Bundles follow the Complete and Reopened rules, and Claude's limits")
    func bundleRules() async throws {
        let world = try await World()
        let one = try await world.create("One")
        let two = try await world.create("Two")
        #expect(await failure { _ = try await world.library.createBundle(in: "HEPH", ticketIDs: []) }
            == .invalid("A bundle needs at least one ticket."))
        let bundle = try await world.library.createBundle(in: "HEPH", ticketIDs: [one, "heph-2"]).id
        #expect(bundle == "HEPH-B1")
        #expect(await world.library.snapshot.bundle(bundle)?.title == "One, Two")
        _ = try await world.library.setStatus(one, to: .done, by: World.me)
        _ = try await world.library.setStatus(two, to: .done, by: World.claude)
        #expect(await world.library.snapshot.bundle(bundle)?.status == .done)
        _ = try await world.library.setStatus(two, to: .review, by: World.me)
        #expect(await world.library.snapshot.bundle(bundle)?.status == .inProgress)
        #expect(await failure { _ = try await world.library.setBundleStatus(bundle, to: .done, by: World.claude) }
            == .forbidden("Only the user can set HEPH-B1 to done."))
        _ = try await world.library.updateBundle(bundle, ticketIDs: [one])
        #expect(await world.library.snapshot.bundle(bundle)?.status == .done)
        #expect(await failure { _ = try await world.library.setBundleStatus(bundle, to: .todo, by: World.claude) }
            == .forbidden("HEPH-B1 is done; only the user can change its status."))
        let done = try await world.library.createBundle(in: "HEPH", title: "Done", ticketIDs: [one]).id
        #expect(await world.library.snapshot.bundle(done)?.status == .done)
        #expect(try world.text("project.yml").contains("nextBundleNumber: 3"))
    }

    @Test("Loading a project completes the bundles whose tickets are all done")
    func completeAtLoad() async throws {
        let world = try await World()
        try world.write("ticket/HEPH-1.yml", "schema: 1\nid: HEPH-1\ntitle: A\nstatus: done\ncreated: 2026-11-01T10:00:00Z\n")
        try world.write("bundle/HEPH-B1.yml", "schema: 1\nid: HEPH-B1\ntitle: B\ncreated: 2026-11-01T10:00:00Z\ntickets:\n- HEPH-1\n")
        try world.write("bundle/HEPH-B2.yml", "schema: 1\nid: HEPH-B2\ntitle: C\ncreated: 2026-11-01T10:00:00Z\ntickets:\n- HEPH-1\n- HEPH-9\n")
        let fresh = TicketLibrary(projects: world.projects, trash: .folder(world.trash), now: { World.date })
        let snapshot = await fresh.sync(with: await world.projects.load())
        #expect(snapshot.bundle("HEPH-B1")?.status == .done)
        #expect(snapshot.bundle("HEPH-B2")?.status == .todo)
        #expect(try world.text("bundle/HEPH-B1.yml").contains("status: done"))
    }

    // MARK: Deleting, comments and attachments

    @Test("Deleting a ticket empties its bundles and links first, then moves its files to the Trash")
    func deleting() async throws {
        let world = try await World()
        let one = try await world.create("One", files: [try world.source("shot.png")])
        let two = try await world.create("Two", links: [.init(kind: .related, ticketID: one)])
        _ = try await world.library.setStatus(two, to: .done, by: World.me)
        let bundle = try await world.library.createBundle(in: "HEPH", ticketIDs: [one, two]).id
        _ = try await world.library.delete([one])
        #expect(await world.ticket(one) == nil)
        #expect(await world.ticket(two)?.file.links == [])
        #expect(await world.library.snapshot.bundle(bundle)?.ticketIDs == [two])
        #expect(await world.library.snapshot.bundle(bundle)?.status == .done)
        #expect(world.trashedNames == ["HEPH-1", "HEPH-1.yml"])
        #expect(!FileManager.default.fileExists(atPath: world.url("ticket/HEPH-1.yml").path))
        _ = try await world.library.deleteBundle(bundle)
        #expect(await world.library.snapshot.bundle(bundle) == nil)
        #expect(await world.ticket(two) != nil)
    }

    @Test("Comments need text or files; deleting one moves its files to the Trash")
    func comments() async throws {
        let world = try await World()
        let id = try await world.create("One")
        #expect(await failure { _ = try await world.library.addComment(to: id, text: "  ", files: [], by: World.me) }
            == .invalid("A comment needs text or at least one attachment."))
        let snapshot = try await world.library.addComment(to: id, text: "Line\r\nTwo", files: [try world.source("log.txt")], by: World.claude)
        let comment = try #require(snapshot.ticket(id)?.file.comments.first)
        #expect(comment.text == "Line\nTwo" && comment.author == .claude)
        #expect(comment.attachments.first?.contentType == "text/plain")
        _ = try await world.library.updateComment(comment.id, of: id, text: "Edited")
        #expect(await world.ticket(id)?.file.comments.first?.updated == World.date)
        #expect(await failure { _ = try await world.library.removeAttachment(comment.attachments[0].id, of: id) }
            == .notFound("Attachment \(comment.attachments[0].id.uuidString) not found."))
        _ = try await world.library.deleteComment(comment.id, of: id)
        #expect(await world.ticket(id)?.file.comments == [])
        #expect(world.trashedNames == [comment.attachments[0].path.components(separatedBy: "/").last!])
    }

    @Test("Attachments are copied under a new id, limited to 20 MB, and removed to the Trash")
    func attachments() async throws {
        let world = try await World()
        let id = try await world.create("One")
        let snapshot = try await world.library.addAttachments([try world.source("a:b.png", bytes: 10)], to: id)
        let attachment = try #require(snapshot.ticket(id)?.file.attachments.first)
        #expect(attachment.name == "a_b.png" && attachment.size == 10 && attachment.contentType == "image/png")
        #expect(attachment.path == "attachments/HEPH-1/\(attachment.id.uuidString)-a_b.png")
        #expect(FileManager.default.fileExists(atPath: world.url(attachment.path).path))
        let large = try world.source("big.bin", bytes: TicketRules.attachmentLimit + 1)
        #expect(await failure { _ = try await world.library.addAttachments([large], to: id) } == .invalid("big.bin is larger than 20 MB."))
        let folder = world.root
        #expect(await failure { _ = try await world.library.addAttachments([folder], to: id) } == .invalid("\(folder.path) is not a readable file."))
        #expect(await failure { _ = try await world.library.attachmentURL("attachments/HEPH-1/../../project.yml", in: "HEPH") }
            == .forbidden("The path is outside the attachments folder."))
        #expect(try await world.library.attachmentURL(attachment.path, in: "HEPH").lastPathComponent.hasSuffix("a_b.png"))
        _ = try await world.library.removeAttachment(attachment.id, of: id)
        #expect(await world.ticket(id)?.file.attachments == [])
        #expect(world.trashedNames.count == 1)
    }

    @Test("Long attachment names are shortened before their extension")
    func attachmentNames() {
        let id = UUID()
        let name = TicketRules.attachmentName(String(repeating: "é", count: 200) + ".png", id: id)
        #expect(name.hasSuffix(".png"))
        #expect((id.uuidString + "-" + name).utf8.count <= 213)
        #expect(TicketRules.attachmentName("", id: id) == "file")
        #expect(TicketRules.attachmentName("a/b\u{7}", id: id) == "a_b_")
    }

    // MARK: Outside changes

    @Test("Files changed outside load again; an invalid file keeps the version loaded; bundles follow")
    func outsideChanges() async throws {
        let world = try await World()
        let one = try await world.create("One")
        let bundle = try await world.library.createBundle(in: "HEPH", ticketIDs: [one]).id
        let path = world.url("ticket/\(one).yml").path
        try world.write("ticket/\(one).yml", try world.text("ticket/\(one).yml").replacingOccurrences(of: "status: todo", with: "status: done"))
        let changed = try #require(await world.library.handle([FileEvent(path: path, kind: .modified)]))
        #expect(changed.ticket(one)?.file.status == .done)
        #expect(changed.bundle(bundle)?.status == .done)
        try world.write("ticket/\(one).yml", "id: [")
        let invalid = try #require(await world.library.handle([FileEvent(path: path, kind: .modified)]))
        #expect(invalid.ticket(one)?.file.status == .done)
        #expect(invalid.invalidFiles[path] != nil)
        try FileManager.default.removeItem(atPath: path)
        let removed = try #require(await world.library.handle([FileEvent(path: path, kind: .removed)]))
        #expect(removed.ticket(one) == nil)
        #expect(removed.bundle(bundle)?.status == .inProgress)
        #expect(await world.library.handle([FileEvent(path: world.root.path + "/elsewhere.txt", kind: .modified)]) == nil)
    }
}
