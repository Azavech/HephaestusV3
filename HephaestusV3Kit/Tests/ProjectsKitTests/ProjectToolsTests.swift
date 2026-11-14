import ExternalTools
import FileStorage
import Foundation
import MCPKit
import ProjectData
import Testing
@testable import ProjectsKit

private final class SilentRunner: ProcessRunning {
    func run(_ request: ProcessRequest, input: Data?, timeout: Duration?) async throws -> ProcessResult {
        ProcessResult(termination: .exited(1))
    }
}

@MainActor
@Suite("Project tools")
struct ProjectToolsTests {
    private func withTools(_ body: (MCPProtocol, ProjectSession, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ProjectsKitTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = ProjectSession(dataFolder: DataFolder(url: root.appendingPathComponent("Data")), runner: SilentRunner(),
                                     hub: FileEventHub(quietDelay: .milliseconds(20), maximumDelay: .milliseconds(100)))
        await session.start()
        let mcp = MCPProtocol(registry: ToolRegistry(ProjectTools.operations(session: session)), version: "1.0")
        try await body(mcp, session, root)
        await session.stop()
    }

    /// Calls a tool; returns its text and whether it is an error.
    private func call(_ mcp: MCPProtocol, _ name: String, _ arguments: JSONValue) async -> (text: String, isError: Bool) {
        let body: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": .string(name), "arguments": arguments]]
        guard case .json(let reply) = await mcp.handle(body: body.data) else { return ("", true) }
        let result = reply["result"]
        return (result?["content"]?.arrayValue?.first?["text"]?.stringValue ?? "", result?["isError"] == true)
    }

    @Test("create, list, get, update and remove a project, as the windows do")
    func lifecycle() async throws {
        try await withTools { mcp, session, root in
            let folder = root.appendingPathComponent("orders").path
            let created = await call(mcp, "create_project", ["path": .string(folder), "name": "Orders", "identifier": "ord", "type": "goService"])
            #expect(!created.isError)
            let detail = try JSONValue.parse(Data(created.text.utf8))
            #expect(detail["id"] == "ORD")
            #expect(detail["type"] == "goService")
            #expect(detail["folder"] == .string(folder))
            #expect(session.snapshot.project("ORD") != nil)
            let listed = try JSONValue.parse(Data(await call(mcp, "list_projects", [:]).text.utf8))
            #expect(listed.arrayValue?.compactMap { $0["id"]?.stringValue } == ["ORD"])
            let updated = await call(mcp, "update_project", ["projectID": "ORD", "name": "Orders API", "color": "#34c759", "icon": "hammer"])
            #expect(!updated.isError)
            #expect(session.snapshot.project("ORD")?.file.color == "#34C759")
            #expect(await call(mcp, "update_project", ["projectID": "ORD", "icon": "no.such.symbol.here"]).text
                == "no.such.symbol.here is not an SF Symbol of this Mac.")
            #expect(await call(mcp, "update_project", ["projectID": "ORD", "color": ""]).isError == false)
            #expect(session.snapshot.project("ORD")?.file.color == nil)
            #expect(await call(mcp, "remove_project", ["projectID": "ORD"]) == ("{}", false))
            #expect(session.snapshot.projects.isEmpty)
            #expect(FileManager.default.fileExists(atPath: folder + "/.hephaestus/project.yml"))
        }
    }

    @Test("Refusals: validation, rules, unknown projects, conflicts")
    func refusals() async throws {
        try await withTools { mcp, _, root in
            #expect(await call(mcp, "create_project", ["path": "relative", "name": "A", "identifier": "AA"]).text
                == "path: use an absolute path or a path starting with ~/.")
            #expect(await call(mcp, "create_project", ["path": "/x", "identifier": "AA"]).text == "name: required.")
            #expect(await call(mcp, "create_project", ["path": "/x", "name": "A", "identifier": "AA", "type": "rust"]).text
                == "type: must be one of none, goService, swiftApplication, library.")
            let folder = root.appendingPathComponent("a").path
            #expect(await call(mcp, "create_project", ["path": .string(folder), "name": "A", "identifier": "A1"]).text
                == "identifier: use 2 to 8 letters A–Z.")
            _ = await call(mcp, "create_project", ["path": .string(folder), "name": "A", "identifier": "AA"])
            #expect(await call(mcp, "create_project", ["path": .string(folder + "/b"), "name": "B", "identifier": "aa"]).text
                == "AA is already used by “A”.")
            #expect(await call(mcp, "get_project", ["projectID": "ZZ"]).text == "No project ZZ.")
            #expect(await call(mcp, "remove_project", ["projectID": "ZZ"]).text == "No project ZZ is loaded.")
            #expect(await call(mcp, "list_projects", ["extra": 1]).text == "extra: unknown argument.")
        }
    }

    @Test("~/ is the home folder")
    func pathExpansion() throws {
        #expect(try ProjectTools.expanded("~/Developer/x", home: "/Users/someone") == "/Users/someone/Developer/x")
        #expect(throws: ToolError.self) { try ProjectTools.expanded("x") }
    }
}
