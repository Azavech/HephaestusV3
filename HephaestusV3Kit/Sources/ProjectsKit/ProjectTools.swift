import AppKit
import Foundation
import MCPKit
import ProjectData
import ToolsFoundation

/// The project operations the MCP server offers Claude (docs/mcp.md › Project tools): the same session
/// calls the Projects window and Project Settings make.
public enum ProjectTools {
    /// `list_projects`, `get_project`, `create_project`, `update_project`, `remove_project`, in this order.
    @MainActor
    public static func operations(session: ProjectSession) -> [ToolOperation] {
        [list(session), get(session), create(session), update(session), remove(session)]
    }

    static let projectID = ToolSchema.string("Project identifier: 2 to 8 letters, for example ORD.")
    static let types = ["none", "goService", "swiftApplication", "library"]

    // MARK: Operations

    @MainActor
    static func list(_ session: ProjectSession) -> ToolOperation {
        ToolOperation(
            name: "list_projects",
            description: "List the projects of Hephaestus V3 on this Mac, sub projects included: identifier, name, type, folder, parent and sub projects.",
            inputSchema: .object(), permission: .read
        ) { @MainActor _ throws(ToolError) in
            try encode(session.snapshot.projects.map(ProjectSummaryJSON.init))
        }
    }

    @MainActor
    static func get(_ session: ProjectSession) -> ToolOperation {
        ToolOperation(
            name: "get_project",
            description: "Get a project: its settings (name, type, color, icon, docs folder, GitHub page, use parent settings, graph enabled), folder, parent, sub projects, and its environments as they apply (environments; for a sub project that uses its parent's settings, the parent's with its changes first, then its own), the inherited ones (inheritedEnvironments) and the one the user works in (currentEnvironment).",
            inputSchema: .object(properties: [("projectID", projectID)], required: ["projectID"]), permission: .read
        ) { @MainActor arguments throws(ToolError) in
            try detail(session, try arguments.string("projectID"))
        }
    }

    @MainActor
    static func create(_ session: ProjectSession) -> ToolOperation {
        ToolOperation(
            name: "create_project",
            description: "Create a project in a folder on this Mac (the folder is created when missing) and add it to Hephaestus V3. The identifier is 2 to 8 letters, unique and permanent: ask the user for the name and the identifier unless they gave them. With parentID the folder must be inside the parent project's folder and the new project becomes its sub project. type is none when omitted.",
            inputSchema: .object(properties: [
                ("path", .string("Absolute path of the project folder, or a path starting with ~/.")),
                ("name", .string("Project name shown in the app.")),
                ("identifier", .string("2 to 8 letters A to Z, stored uppercase, unique on this Mac, never changed.")),
                ("type", .string("Project type: none, goService (a service), swiftApplication (an app) or library.", oneOf: types)),
                ("parentID", .string("Identifier of the parent project, to create a sub project.")),
            ], required: ["path", "name", "identifier"]),
            permission: .change
        ) { @MainActor arguments throws(ToolError) in
            let path = try expanded(try arguments.string("path"))
            let kind = ProjectKind(rawValue: arguments["type"]?.stringValue ?? "none") ?? ProjectKind.none
            let request = NewProject(name: try arguments.string("name"), identifier: try arguments.string("identifier"), kind: kind,
                                     folder: path, createsFolder: true, parentID: arguments["parentID"]?.stringValue)
            let id: String
            do throws(ProjectError) {
                id = try await session.create(request)
            } catch {
                throw toolError(error)
            }
            return try detail(session, id)
        }
    }

    @MainActor
    static func update(_ session: ProjectSession) -> ToolOperation {
        ToolOperation(
            name: "update_project",
            description: "Change a project's name, type, color, icon or docs folder. Omitted arguments are left unchanged. color is a tint (accent, accentSecondary, info, success, warning) or a hex color #RRGGBB, and an empty color removes it. icon is the name of an SF Symbol of this Mac, for example hammer, and an empty icon removes it.",
            inputSchema: .object(properties: [
                ("projectID", projectID),
                ("name", .string("New project name.")),
                ("type", .string("Project type: none, goService (a service), swiftApplication (an app) or library.", oneOf: types)),
                ("color", .string("The project's tint: accent, accentSecondary, info, success, warning, or #RRGGBB; an empty string removes it.")),
                ("icon", .string("Name of an SF Symbol of this Mac shown as the project's icon, for example hammer; an empty string removes it.")),
                ("docsPath", .string("Docs folder relative to the project's folder, for example docs.")),
            ], required: ["projectID"]),
            permission: .change
        ) { @MainActor arguments throws(ToolError) in
            let id = try arguments.string("projectID")
            guard session.snapshot.project(id) != nil else { throw notFound(id) }
            var change = ProjectChange()
            change.name = arguments["name"]?.stringValue
            change.kind = arguments["type"]?.stringValue.flatMap(ProjectKind.init(rawValue:))
            if let color = arguments["color"]?.stringValue { change.color = .some(color.isEmpty ? nil : color) }
            if let icon = arguments["icon"]?.stringValue?.trimmingCharacters(in: .whitespaces) {
                if !icon.isEmpty, NSImage(systemSymbolName: icon, accessibilityDescription: nil) == nil {
                    throw ToolError(.invalid, "\(icon) is not an SF Symbol of this Mac.")
                }
                change.icon = .some(icon.isEmpty ? nil : icon)
            }
            change.docsPath = arguments["docsPath"]?.stringValue
            do throws(ProjectError) {
                try await session.update(id, change)
            } catch {
                throw toolError(error)
            }
            return try detail(session, id)
        }
    }

    @MainActor
    static func remove(_ session: ProjectSession) -> ToolOperation {
        ToolOperation(
            name: "remove_project",
            description: "Remove a project and its sub projects from Hephaestus V3 on this Mac. Their folders and files are left untouched; adding the folder again brings the project back.",
            inputSchema: .object(properties: [("projectID", projectID)], required: ["projectID"]), permission: .change
        ) { @MainActor arguments throws(ToolError) in
            let id = try arguments.string("projectID")
            do throws(ProjectError) {
                try await session.remove(id)
            } catch {
                throw toolError(error)
            }
            return [:]
        }
    }

    // MARK: Helpers

    @MainActor
    static func detail(_ session: ProjectSession, _ id: String) throws(ToolError) -> JSONValue {
        guard let project = session.snapshot.project(id) else { throw notFound(id) }
        return try encode(ProjectDetailJSON(project))
    }

    static func notFound(_ id: String) -> ToolError {
        ToolError(.notFound, "No project \(id).")
    }

    /// `~/` is the home folder; the result must be absolute.
    static func expanded(_ path: String, home: String = NSHomeDirectory()) throws(ToolError) -> String {
        let expanded = path.hasPrefix("~/") ? home + path.dropFirst() : path
        guard expanded.hasPrefix("/") else { throw ToolError(.invalid, "path: use an absolute path or a path starting with ~/.") }
        return expanded
    }

    /// The code of each failure, and its English message.
    static func toolError(_ error: ProjectError) -> ToolError {
        let code: ToolError.Code = switch error {
        case .rule(.identifierInUse), .alreadyContainsProject: .conflict
        case .rule, .notInsideParent: .invalid
        case .projectNotLoaded, .noProject, .folderMissing, .unknownEnvironment: .notFound
        case .noDataFolder: .unavailable
        case .storage: .internal
        }
        return ToolError(code, error.description)
    }

    static func encode<T: Encodable>(_ value: T) throws(ToolError) -> JSONValue {
        do {
            return try JSONValue(encoding: value)
        } catch {
            throw ToolError(.internal, "The result can't be encoded: \(error).")
        }
    }
}

/// A project in `list_projects`.
struct ProjectSummaryJSON: Encodable {
    let id: String
    let name: String
    let type: String
    let folder: String
    let parentID: String?
    let subprojects: [String]
    let fileIssue: String?

    init(_ project: LoadedProject) {
        id = project.id
        name = project.file.name
        type = project.file.type.rawValue
        folder = project.root
        parentID = project.parentID
        subprojects = project.childIDs
        fileIssue = project.fileIssue
    }
}

/// A project in `get_project`, `create_project` and `update_project`.
struct ProjectDetailJSON: Encodable {
    struct Environment: Encodable {
        let name: String
        let url: String?
        let port: Int?
        let baseURL: String?
        let allowInvalidCertificates: Bool
        let namespace: String?
        let deployment: String?
        let jaeger: String?
        let argoCDApplication: String?
        let kubeconfig: String?

        init(_ entry: EnvironmentEntry) {
            name = entry.name
            url = entry.url
            port = entry.port
            baseURL = entry.baseURL
            allowInvalidCertificates = entry.allowInvalidCertificates
            namespace = entry.namespace
            deployment = entry.deployment
            jaeger = entry.jaeger
            argoCDApplication = entry.argoCDApplication
            kubeconfig = entry.kubeconfig
        }
    }

    let id: String
    let name: String
    let type: String
    let color: String?
    let icon: String?
    let folder: String
    let parentID: String?
    let subprojects: [String]
    let docsPath: String
    let githubPage: String?
    let useParentSettings: Bool
    let graphEnabled: Bool
    let environments: [Environment]
    let inheritedEnvironments: [Environment]
    let currentEnvironment: String?
    let fileIssue: String?

    init(_ project: LoadedProject) {
        let file = project.file
        id = file.id
        name = file.name
        type = file.type.rawValue
        color = file.color
        icon = file.icon
        folder = project.root
        parentID = project.parentID
        subprojects = project.childIDs
        docsPath = file.docsPath
        githubPage = project.resolved.githubPage
        useParentSettings = file.useParentSettings
        graphEnabled = project.resolved.graphEnabled
        environments = project.resolved.environments.map(Environment.init)
        inheritedEnvironments = project.resolved.inheritedEnvironments.map(Environment.init)
        currentEnvironment = project.resolved.currentEnvironment
        fileIssue = project.fileIssue
    }
}
