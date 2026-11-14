import Foundation
import MCPKit
import ProjectData
import ProjectsKit
import ToolsFoundation

/// Every tool operation the MCP server offers, in the order of `tools/list` (docs/mcp.md › Tools): each
/// available feature's operations, then `open_in_app`.
@MainActor
enum AppTools {
    /// `open` shows a route in a window, and says whether a window could.
    static func registry(session: ProjectSession, open: @escaping @MainActor (Route) -> Bool) -> ToolRegistry {
        ToolRegistry(ProjectTools.operations(session: session) + [openInApp(session: session, open: open)])
    }

    static func openInApp(session: ProjectSession, open: @escaping @MainActor (Route) -> Bool) -> ToolOperation {
        ToolOperation(
            name: "open_in_app",
            description: "Show something to the user in Hephaestus V3: a project in the Projects window, or a project's settings.",
            inputSchema: .object(properties: [
                ("target", .object(
                    "What to show. kind decides the other properties: project: projectID; projectSettings: projectID.",
                    properties: [
                        ("kind", .string("Kind of item to show.", oneOf: ["project", "projectSettings"])),
                        ("projectID", .string("Project identifier: 2 to 8 letters, for example ORD.")),
                    ],
                    required: ["kind", "projectID"]
                )),
            ], required: ["target"]),
            permission: .read
        ) { @MainActor arguments throws(ToolError) in
            guard let target = arguments["target"] else { throw ToolError(.invalid, "target: required.") }
            let id = try target.string("projectID")
            guard session.snapshot.project(id) != nil else { throw ToolError(.notFound, "No project \(id).") }
            let route: Route = try target.string("kind") == "projectSettings" ? .projectSettings(id) : .project(id)
            guard open(route) else { throw ToolError(.unavailable, "The app has no window to show it in.") }
            return [:]
        }
    }
}
