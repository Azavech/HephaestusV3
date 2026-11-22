import ServiceMapKit
import ContractsKit
import ChatData
import Foundation
import MCPKit
import MachineData
import ProjectData
import TicketData
import Testing
@testable import ToolsScenes

/// docs/mcp.md › Tools lists exactly the registered tools, in their order, with their exact descriptions and
/// input schemas.
@Suite("MCP documentation")
struct MCPDocumentationTests {
    /// Each `### <tool>` of a section, Tools by default: the first `text` block and the first `json` block after it.
    private func documentedTools(section heading: String = "Tools") throws -> [(name: String, description: String, schema: JSONValue)] {
        let docs = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/mcp.md")
        let text = try String(contentsOf: docs, encoding: .utf8)
        let tools = try #require(text.components(separatedBy: "\n## \(heading)\n").last).components(separatedBy: "\n## ").first ?? ""
        return try tools.components(separatedBy: "\n### ").dropFirst().map { section in
            let name = String(section.prefix { $0 != "\n" })
            func block(_ language: String) throws -> String {
                let start = try #require(section.range(of: "```\(language)\n"), "\(name): no \(language) block")
                let rest = section[start.upperBound...]
                let end = try #require(rest.range(of: "\n```"), "\(name): unclosed block")
                return String(rest[..<end.lowerBound])
            }
            return (name, try block("text"), try JSONValue.parse(Data(try block("json").utf8)))
        }
    }

    @Test("The page and the registry agree")
    @MainActor
    func toolsMatch() throws {
        let session = ProjectSession(dataFolder: nil)
        let tickets = TicketSession(projects: session, device: "Test")
        let chats = ChatSession(projects: session, tokens: MCPTokens(), device: "Test")
        let registry = AppTools.registry(session: session, tickets: tickets, chats: chats,
                                         contracts: LiveContractStore(projects: session), maps: LiveServiceMapStore(projects: session),
                                         machines: MachineHost(dataFolder: nil), implementer: Implementer(tickets: tickets, chats: chats)) { _ in true }
        let documented = try documentedTools()
        #expect(documented.map(\.name) == registry.names)
        for (name, description, schema) in documented {
            let operation = try #require(registry[name])
            #expect(description == operation.description, "\(name)'s description")
            #expect(schema == operation.inputSchema.json, "\(name)'s input schema")
        }
        // The debug tools: listed only with the switch, after the others, as their own section says.
        let debug = AppTools.registry(session: session, tickets: tickets, chats: chats,
                                      contracts: LiveContractStore(projects: session), maps: LiveServiceMapStore(projects: session),
                                      machines: MachineHost(dataFolder: nil), implementer: Implementer(tickets: tickets, chats: chats),
                                      debugTools: true) { _ in true }
        let documentedDebug = try documentedTools(section: "Debug tools")
        #expect(debug.names == registry.names + documentedDebug.map(\.name))
        for (name, description, schema) in documentedDebug {
            let operation = try #require(debug[name])
            #expect(description == operation.description, "\(name)'s description")
            #expect(schema == operation.inputSchema.json, "\(name)'s input schema")
        }
    }
}
