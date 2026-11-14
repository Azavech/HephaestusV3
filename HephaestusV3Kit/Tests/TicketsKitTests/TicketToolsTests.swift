import ExternalTools
import FileStorage
import Foundation
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
        projects = ProjectSession(dataFolder: data, runner: NoProcesses(), v2Folder: root.appendingPathComponent("NoV2"), processEnvironment: [:])
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
    @Test("The tools are V2's, without Implement, in the order of docs/mcp.md")
    func names() async throws {
        let world = try await ToolWorld()
        defer { Task { await world.close() } }
        #expect(TicketTools.operations(tickets: world.tickets, projects: world.projects).map(\.name) == [
            "list_tickets", "get_ticket", "create_ticket", "update_ticket", "delete_ticket", "set_ticket_status", "add_comment",
            "update_comment", "delete_comment", "remove_attachment", "list_bundles", "get_bundle", "create_bundle", "update_bundle",
            "set_bundle_status", "delete_bundle",
        ])
    }

    @Test("Claude creates a ticket with the template, comments with a file, and the window's session sees it")
    func ticketLifecycle() async throws {
        let world = try await ToolWorld()
        defer { Task { await world.close() } }
        let refused = await world.failure("create_ticket", ["projectID": "ORD", "description": "Fix it"])
        #expect(refused?.code == .invalid)
        let ticket = try await world.call("create_ticket", ["projectID": "ord", "title": "Retries", "description": .string(TicketRules.template),
                                                            "priority": "high", "labels": ["api"]])
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
        _ = try await world.call("create_ticket", ["projectID": "ORD", "description": .string(TicketRules.template)])
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
