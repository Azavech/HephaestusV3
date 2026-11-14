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

    static let projectID = ToolSchema.string("Project identifier, 2 to 8 letters, such as ORD.")
    static let types = ["none", "goService", "swiftApplication", "library"]

    // MARK: Operations

    @MainActor
    static func list(_ session: ProjectSession) -> ToolOperation {
        ToolOperation(
            name: "list_projects",
            description: "Returns every project in Hephaestus V3, sub projects included, each with its identifier, name, type, folder, parent and sub projects.",
            inputSchema: .object(), permission: .read,
            describe: ProjectTools.describe("list_projects")
        ) { @MainActor _ throws(ToolError) in
            try encode(session.snapshot.projects.map(ProjectSummaryJSON.init))
        }
    }

    @MainActor
    static func get(_ session: ProjectSession) -> ToolOperation {
        ToolOperation(
            name: "get_project",
            description: "Returns one project: its settings (name, type, color, icon, docs folder, GitHub page, graph enabled), folder, parent and sub projects, and its environments. A sub project takes each setting it leaves empty from its parent: githubPage and graphEnabled are the values that apply. environments holds those that apply: the parent's with this project's changes, then its own. inheritedEnvironments holds the parent's as they are, and currentEnvironment the one selected in the app.",
            inputSchema: .object(properties: [("projectID", projectID)], required: ["projectID"]), permission: .read,
            describe: ProjectTools.describe("get_project")
        ) { @MainActor arguments throws(ToolError) in
            try detail(session, try arguments.string("projectID"))
        }
    }

    @MainActor
    static func create(_ session: ProjectSession) -> ToolOperation {
        ToolOperation(
            name: "create_project",
            description: "Adds a project to Hephaestus V3 for a folder on this Mac, creating the folder if it doesn't exist. The identifier can't be changed later. With parentID, the project becomes a sub project of that parent, whose folder must contain this one. Without type, the type is none.",
            inputSchema: .object(properties: [
                ("path", .string("The project's folder: an absolute path, or one starting with ~/.")),
                ("name", .string("The name the app shows.")),
                ("identifier", .string("2 to 8 letters A–Z, saved in uppercase, not used by another project.")),
                ("type", .string("none, goService (a service), swiftApplication (an app) or library.", oneOf: types)),
                ("parentID", .string("The parent's identifier, for a sub project.")),
            ], required: ["path", "name", "identifier"]),
            permission: .changeProjects,
            describe: ProjectTools.describe("create_project")
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
            description: "Changes a project's name, type, color, icon or docs folder. Arguments left out keep their value, and an empty color or icon clears it.",
            inputSchema: .object(properties: [
                ("projectID", projectID),
                ("name", .string("The new name.")),
                ("type", .string("none, goService (a service), swiftApplication (an app) or library.", oneOf: types)),
                ("color", .string("A tint (accent, accentSecondary, info, success, warning) or #RRGGBB.")),
                ("icon", .string("An SF Symbol name, such as hammer.")),
                ("docsPath", .string("The docs folder, relative to the project's folder, such as docs.")),
            ], required: ["projectID"]),
            permission: .changeProjects,
            describe: ProjectTools.describe("update_project")
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
            description: "Removes a project and its sub projects from Hephaestus V3. Nothing on disk is deleted: adding the folder again restores the project.",
            inputSchema: .object(properties: [("projectID", projectID)], required: ["projectID"]), permission: .removeProjects,
            describe: ProjectTools.describe("remove_project")
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
        graphEnabled = project.resolved.graphEnabled
        environments = project.resolved.environments.map(Environment.init)
        inheritedEnvironments = project.resolved.inheritedEnvironments.map(Environment.init)
        currentEnvironment = project.resolved.currentEnvironment
        fileIssue = project.fileIssue
    }
}

// MARK: Chat

extension ProjectTools {
    /// How a chat shows a call of the tool `name` (docs/ui/chat.md › Tool-call rows). A project's item has the
    /// tool `projects`: no window of a tool shows it alone, so the row has no Open.
    static func describe(_ name: String) -> @Sendable (JSONValue) -> ToolCallText {
        { arguments in text(name, arguments) }
    }

    nonisolated static func text(_ name: String, _ arguments: JSONValue) -> ToolCallText {
        let id = (arguments["projectID"]?.stringValue ?? arguments["identifier"]?.stringValue ?? "").uppercased()
        let projectName = arguments["name"]?.stringValue ?? id
        let item = ToolItem(tool: "projects", projectID: id, focus: "", title: projectName)
        switch name {
        case "list_projects":
            return ToolCallText(action: String(localized: "Listed the projects", bundle: #bundle))
        case "get_project":
            return ToolCallText(action: String(localized: "Read project \(id)", bundle: #bundle), item: item)
        case "create_project":
            let path = arguments["path"]?.stringValue ?? ""
            return ToolCallText(action: String(localized: "Added the project \(projectName)", bundle: #bundle),
                                request: String(localized: "Claude wants to add the project \(projectName)", bundle: #bundle),
                                preview: "\(id) · \(path)", item: item)
        case "update_project":
            let changes = (arguments.objectValue ?? [:]).filter { $0.key != "projectID" }.sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value.stringValue ?? $0.value.text)" }
            return ToolCallText(action: String(localized: "Changed the settings of \(id)", bundle: #bundle),
                                request: String(localized: "Claude wants to change the settings of \(id)", bundle: #bundle),
                                preview: changes.isEmpty ? nil : changes.joined(separator: "\n"), item: item)
        case "remove_project":
            return ToolCallText(action: String(localized: "Removed \(id) from Hephaestus", bundle: #bundle),
                                request: String(localized: "Claude wants to remove \(id) from Hephaestus", bundle: #bundle),
                                preview: String(localized: "The project's folder and files stay on this Mac.", bundle: #bundle), item: item)
        default:
            return ToolCallText(action: name)
        }
    }
}
