import ExternalTools
import FileStorage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import MCPKit
import ProjectData
import TicketData
import Testing
import ToolsFoundation
@testable import TicketsKit

/// Starts no process: every run fails.
private struct NoProcesses: ProcessRunning {
    func run(_ request: ProcessRequest, input: Data?, timeout: Duration?) async throws -> ProcessResult {
        ProcessResult(termination: .exited(1))
    }
}

/// The ticket tools on real sessions over a temporary data folder and project, deleted afterwards.
@MainActor
private final class ToolWorld {
    let root: URL
    let projects: ProjectSession
    let tickets: TicketSession
    let operations: [String: ToolOperation]

    init() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("TicketToolsTests-\(UUID().uuidString)").resolvingSymlinksInPath()
        let repo = root.appendingPathComponent("Repo")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".hephaestus"), withIntermediateDirectories: true)
        try Data("schema: 1\nid: ORD\nname: Orders\ncreated: 2026-10-31T09:30:00Z\n".utf8).write(to: repo.appendingPathComponent(".hephaestus/project.yml"))
        try Data("log".utf8).write(to: repo.appendingPathComponent("run.log"))
        let data = DataFolder(url: root.appendingPathComponent("Data"))
        try data.createIfNeeded()
        try YAMLFile.write(RegistryFile(projects: [repo.path]), to: data.registryFile)
        projects = ProjectSession(dataFolder: data, runner: NoProcesses(), processEnvironment: [:])
        await projects.start()
        tickets = TicketSession(projects: projects, trash: .folder(root.appendingPathComponent("Trash")), device: "Test")
        await tickets.start()
        operations = Dictionary(uniqueKeysWithValues: TicketTools.operations(tickets: tickets, projects: projects).map { ($0.name, $0) })
    }

    func call(_ name: String, _ arguments: JSONValue) async throws(ToolError) -> JSONValue {
        try await operations[name]!.run(arguments)
    }

    func failure(_ name: String, _ arguments: JSONValue) async -> ToolError? {
        do {
            _ = try await call(name, arguments)
            return nil
        } catch {
            return error
        }
    }

    func close() async {
        await projects.stop()
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("Ticket tools")
@MainActor
struct TicketToolsTests {
    @Test("The tools, in the order of docs/mcp.md")
    func names() async throws {
        let world = try await ToolWorld()
        defer { Task { await world.close() } }
        #expect(TicketTools.operations(tickets: world.tickets, projects: world.projects).map(\.name) == [
            "list_tickets", "get_ticket", "get_attachment", "create_ticket", "update_ticket", "delete_ticket", "set_ticket_status", "add_comment",
            "update_comment", "delete_comment", "remove_attachment", "list_bundles", "get_bundle", "create_bundle", "update_bundle",
            "set_bundle_status", "delete_bundle",
        ])
    }

    /// A PNG of `width` × `height` pixels, all one color.
    private func png(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.4, green: 0.2, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test("get_attachment returns an image as an image, scaled down past 1568 pixels; a text as its text; another file refused")
    func attachments() async throws {
        let world = try await ToolWorld()
        defer { Task { await world.close() } }
        let repo = world.root.appendingPathComponent("Repo")
        try png(width: 2000, height: 1000).write(to: repo.appendingPathComponent("shot.png"))
        try png(width: 40, height: 30).write(to: repo.appendingPathComponent("small.png"))
        try Data([0x00, 0x01, 0x02, 0xFF]).write(to: repo.appendingPathComponent("blob.bin"))
        let ticket = try await world.call("create_ticket", ["projectID": "ORD", "title": "Crash", "description": "See the files.",
                                                            "attachments": ["shot.png", "small.png", "blob.bin"]])
        let commented = try await world.call("add_comment", ["ticketID": "ORD-1", "text": "The log.", "attachments": ["run.log"]])
        func id(_ name: String, in list: JSONValue?) -> String {
            list?.arrayValue?.first { $0["name"]?.stringValue == name }?["id"]?.stringValue ?? ""
        }
        let files = ticket["attachments"]
        let log = id("run.log", in: commented["comments"]?.arrayValue?.first?["attachments"])

        let shot = try await world.call("get_attachment", ["ticketID": "ord-1", "attachmentID": .string(id("shot.png", in: files))])
        #expect(shot["type"]?.stringValue == "image" && shot["mimeType"]?.stringValue == "image/png")
        let data = try #require(Data(base64Encoded: shot["data"]?.stringValue ?? ""))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 1568)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 784)

        let small = try await world.call("get_attachment", ["ticketID": "ORD-1", "attachmentID": .string(id("small.png", in: files))])
        let smallData = try #require(Data(base64Encoded: small["data"]?.stringValue ?? ""))
        let smallSource = try #require(CGImageSourceCreateWithData(smallData as CFData, nil))
        #expect((CGImageSourceCopyPropertiesAtIndex(smallSource, 0, nil) as? [CFString: Any])?[kCGImagePropertyPixelWidth] as? Int == 40,
                "A small image keeps its size")

        let text = try await world.call("get_attachment", ["ticketID": "ORD-1", "attachmentID": .string(log)])
        #expect(text["text"]?.stringValue == "log" && text["truncated"]?.boolValue == false && text["name"]?.stringValue == "run.log")

        let binary = await world.failure("get_attachment", ["ticketID": "ORD-1", "attachmentID": .string(id("blob.bin", in: files))])
        #expect(binary?.code == .invalid)
        #expect(binary?.message.contains("/Repo/.hephaestus/attachments/ORD-1/") == true)
        #expect(await world.failure("get_attachment", ["ticketID": "ORD-1", "attachmentID": .string(UUID().uuidString)])?.code == .notFound)
        #expect(await world.failure("get_attachment", ["ticketID": "ORD-9", "attachmentID": .string(log)])?.code == .notFound)
    }

    @Test("A text is cut after 256 KB on a character's boundary; NUL bytes or invalid UTF-8 aren't text")
    func textLimits() throws {
        let long = Data(String(repeating: "a", count: AttachmentContent.maxTextBytes - 1).utf8) + Data("é and more".utf8)
        let cut = try #require(AttachmentContent.text(long))
        #expect(cut.truncated && cut.text.utf8.count == AttachmentContent.maxTextBytes - 1)
        #expect(AttachmentContent.text(Data("plain".utf8))?.truncated == false)
        #expect(AttachmentContent.text(Data([0x61, 0x00, 0x62])) == nil)
        #expect(AttachmentContent.text(Data([0xC3, 0x28])) == nil)
        #expect(ClaudeImage.isImage(contentType: "application/octet-stream", url: URL(fileURLWithPath: "/a/shot.jpeg")))
        #expect(!ClaudeImage.isImage(contentType: "text/plain", url: URL(fileURLWithPath: "/a/run.log")))
    }

    @Test("Claude creates a ticket with a free description, comments with a file, and the window's session sees it")
    func ticketLifecycle() async throws {
        let world = try await ToolWorld()
        defer { Task { await world.close() } }
        let refused = await world.failure("create_ticket", ["projectID": "ORD", "title": "Two\nlines", "description": "Fix it"])
        #expect(refused?.code == .invalid)
        let ticket = try await world.call("create_ticket", ["projectID": "ord", "title": "Retries", "description": "Retries stop after one timeout.",
                                                            "priority": "high", "labels": ["api"]])
        #expect(ticket["description"]?.stringValue == "Retries stop after one timeout.")
        #expect(ticket["id"]?.stringValue == "ORD-1")
        #expect(ticket["status"]?.stringValue == "todo" && ticket["createdBy"]?.stringValue == "claude")
        #expect(ticket["priority"]?.stringValue == "high")
        #expect(world.tickets.snapshot.ticket("ORD-1") != nil)
        let commented = try await world.call("add_comment", ["ticketID": "ORD-1", "text": "Log attached.", "attachments": ["run.log"]])
        let path = commented["comments"]?.arrayValue?.first?["attachments"]?.arrayValue?.first?["path"]?.stringValue ?? ""
        #expect(path.hasPrefix(world.root.path + "/Repo/.hephaestus/attachments/ORD-1/"))
        #expect(FileManager.default.fileExists(atPath: path))
        let listed = try await world.call("list_tickets", ["projectID": "ORD", "status": "todo"])
        #expect(listed.arrayValue?.count == 1)
        #expect(try await world.call("list_tickets", ["projectID": "ORD", "status": "done"]).arrayValue?.isEmpty == true)
    }

    @Test("Claude's status limits and the bundles' automatic rules hold through the tools")
    func statusAndBundles() async throws {
        let world = try await ToolWorld()
        defer { Task { await world.close() } }
        _ = try await world.call("create_ticket", ["projectID": "ORD", "description": "Fix it"])
        let bundle = try await world.call("create_bundle", ["projectID": "ORD", "ticketIDs": ["ORD-1"]])
        #expect(bundle["id"]?.stringValue == "ORD-B1" && bundle["status"]?.stringValue == "todo")
        #expect(await world.failure("set_ticket_status", ["ticketID": "ORD-1", "status": "draft"])?.message
            == "status: must be one of todo, in_progress, review, done.")
        _ = try await world.call("set_ticket_status", ["ticketID": "ORD-1", "status": "done"])
        #expect(try await world.call("get_bundle", ["bundleID": "ORD-B1"])["status"]?.stringValue == "done")
        let forbidden = await world.failure("set_ticket_status", ["ticketID": "ORD-1", "status": "review"])
        #expect(forbidden == ToolError(.forbidden, "ORD-1 is done; only the user can change its status."))
        #expect(await world.failure("set_bundle_status", ["bundleID": "ORD-B1", "status": "todo"])?.code == .forbidden)
        _ = try await world.call("delete_ticket", ["ticketID": "ORD-1"])
        #expect(world.tickets.snapshot.ticket("ORD-1") == nil)
        #expect(try await world.call("get_bundle", ["bundleID": "ORD-B1"])["tickets"]?.arrayValue?.isEmpty == true)
        #expect(await world.failure("get_ticket", ["ticketID": "ORD-1"]) == ToolError(.notFound, "Ticket ORD-1 not found."))
        #expect(await world.failure("list_bundles", ["projectID": "XYZ"])?.code == .notFound)
    }
}

/// The first ticket a feedback chat's Claude creates lists the chat, and the chat records it (docs/ui/chat.md ›
/// Feedback).
@Suite("Feedback link")
@MainActor
struct FeedbackLinkTests {
    @Test("A feedback chat's first ticket lists the chat; its later tickets and other callers' don't")
    func link() async throws {
        let world = try await ToolWorld()
        defer { Task { await world.close() } }
        var unlinked: Set<String> = ["FEEDBACK"]
        var linked: [String: String] = [:]
        let feedback = FeedbackLink(isUnlinked: { unlinked.contains($0) }, link: { chat, ticket in
            unlinked.remove(chat)
            linked[chat] = ticket
        })
        let create = try #require(TicketTools.operations(tickets: world.tickets, projects: world.projects, feedback: feedback)
            .first { $0.name == "create_ticket" })
        func call(as caller: MCPCaller) async throws -> JSONValue {
            try await MCPCaller.$current.withValue(caller) {
                try await create.run(["projectID": "ORD", "title": "From feedback", "description": "Seen in the feedback."])
            }
        }
        let first = try await call(as: .chat("FEEDBACK"))
        #expect(first["chats"]?.arrayValue?.compactMap(\.stringValue) == ["FEEDBACK"])
        #expect(linked == ["FEEDBACK": "ORD-1"])
        let second = try await call(as: .chat("FEEDBACK"))
        #expect(second["chats"]?.arrayValue?.isEmpty == true)
        let external = try await call(as: .external)
        #expect(external["chats"]?.arrayValue?.isEmpty == true)
        #expect(linked.count == 1)
    }
}
