import FileStorage
import Foundation
import MCPKit
import ProjectData
import TicketData
import ToolsFoundation

/// The ticket and bundle operations the MCP server offers Claude (docs/mcp.md › Ticket tools): the same
/// library the Tickets window changes, as Claude, with V2's rules for Claude.
public enum TicketTools {
    /// The ticket tools, then the bundle tools, in the order of docs/mcp.md.
    @MainActor
    public static func operations(tickets: TicketSession, projects: ProjectSession) -> [ToolOperation] {
        let tools = TicketToolSet(tickets: tickets, projects: projects)
        return [tools.listTickets, tools.getTicket, tools.createTicket, tools.updateTicket, tools.deleteTicket, tools.setTicketStatus,
                tools.addComment, tools.updateComment, tools.deleteComment, tools.removeAttachment,
                tools.listBundles, tools.getBundle, tools.createBundle, tools.updateBundle, tools.setBundleStatus, tools.deleteBundle]
    }

    /// Claude with the external token; the chats' own tokens come with Chat.
    static let claude = TicketActor.claude(chat: "external")
    static let projectID = ToolSchema.string("Project identifier: 2 to 8 letters, for example ORD.")
    static let ticketID = ToolSchema.string("Ticket id, for example ORD-12.")
    static let bundleID = ToolSchema.string("Bundle id, for example ORD-B2.")
    static let attachments = ToolSchema.array("Files on this Mac to attach: absolute paths, paths starting with ~/, or paths relative to the project's folder.", of: .string())
    static let priority = ToolSchema.string("Priority: low, medium, high or urgent; an empty string removes it.", oneOf: ["", "low", "medium", "high", "urgent"])
    static let labels = ToolSchema.array("Labels, replacing the current ones; [] removes them all.", of: .string())
    static func links(_ description: String) -> ToolSchema {
        .array(description, of: .object(properties: [
            ("kind", .string("dependsOn when this ticket needs the other ticket to be done first, related otherwise.", oneOf: ["dependsOn", "related"])),
            ("ticket", .string("Id of a ticket of the same project, for example ORD-15.")),
        ], required: ["kind", "ticket"]))
    }
}

/// The operations, over one ticket session and its projects.
@MainActor
private struct TicketToolSet {
    let tickets: TicketSession
    let projects: ProjectSession

    init(tickets: TicketSession, projects: ProjectSession) {
        self.tickets = tickets
        self.projects = projects
    }
}

extension TicketToolSet {
    // MARK: Tickets

    var listTickets: ToolOperation {
        ToolOperation(
            name: "list_tickets",
            description: "List a project's tickets, those of its sub projects included, optionally only those with one status: draft, todo, in_progress, review or done.",
            inputSchema: .object(properties: [
                ("projectID", TicketTools.projectID),
                ("status", .string("Only list tickets with this status.", oneOf: ["draft", "todo", "in_progress", "review", "done"])),
            ], required: ["projectID"]),
            permission: .read
        ) { @MainActor arguments throws(ToolError) in
            let id = try arguments.string("projectID").uppercased()
            guard projects.snapshot.project(id) != nil else { throw ToolError(.notFound, "Project \(id) not found.") }
            let snapshot = try await library().snapshot
            let status = arguments["status"]?.stringValue
            let list = projects.snapshot.family(of: id).flatMap { snapshot.tickets[$0.id] ?? [] }.filter { status == nil || $0.file.status.rawValue == status }
            return try encode(list.map(json))
        }
    }

    var getTicket: ToolOperation {
        ToolOperation(
            name: "get_ticket",
            description: "Get a ticket: title, status, priority, labels, dates, creator, description, attachments (with their absolute paths), comments, chat ids, links and history. links are the links the ticket declares (dependsOn, related); inverseLinks are the links other tickets declare to it (blocks, related). history lists its creation, status changes, renames, link changes and description edits with their authors and dates.",
            inputSchema: .object(properties: [("ticketID", TicketTools.ticketID)], required: ["ticketID"]),
            permission: .read
        ) { @MainActor arguments throws(ToolError) in
            try await ticketResult(try arguments.string("ticketID"))
        }
    }

    var createTicket: ToolOperation {
        ToolOperation(
            name: "create_ticket",
            description: """
                Create a ticket in a project. It starts as todo. Without a title, its title is the description's first line that is not a heading. The description must use this template, the six headings alone on their lines and in this order:
                Problem
                (Explain the problem)
                Current Behavior
                (Explain the current behaviour)
                Expected
                (Explain the behaviour that should be expected)
                Change
                (Explain what should change)
                Testing
                (List the tests that decide whether the ticket is done)
                Docs
                (List all docs files and paragraphs relevant to the issue)
                attachments are paths of files on this Mac (absolute, starting with ~/, or relative to the project's folder) that are copied into the ticket. links are links to other tickets of the same project: dependsOn when this ticket needs the other ticket to be done first, related when they are only related.
                """,
            inputSchema: .object(properties: [
                ("projectID", TicketTools.projectID),
                ("title", .string("Ticket title, one line of 1 to 200 characters.")),
                ("description", .string("Ticket description following the template.")),
                ("priority", TicketTools.priority),
                ("labels", TicketTools.labels),
                ("attachments", TicketTools.attachments),
                ("links", TicketTools.links("Links to other tickets of the same project.")),
            ], required: ["projectID", "description"]),
            permission: .change
        ) { @MainActor arguments throws(ToolError) in
            let projectID = try arguments.string("projectID").uppercased()
            let request = TicketLibrary.NewTicket(
                projectID: projectID, title: arguments["title"]?.stringValue ?? "", description: try arguments.string("description"),
                priority: arguments["priority"]?.stringValue.flatMap(TicketFilePriority.init(rawValue:)),
                labels: arguments["labels"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                links: try links(arguments["links"]), attachments: try files(arguments["attachments"], in: projectID)
            )
            let library = try library()
            let id: String
            do throws(TicketError) {
                id = try await library.create(request, by: TicketTools.claude).id
            } catch {
                throw ticketToolError(error)
            }
            await tickets.refresh()
            return try await ticketResult(id)
        }
    }

    var updateTicket: ToolOperation {
        ToolOperation(
            name: "update_ticket",
            description: "Change a ticket's title, description, priority, labels or links. Omitted arguments are left unchanged; a new description must follow the same template as create_ticket; links replaces the links the ticket declares, so list every link to keep, and [] removes them all. Use set_ticket_status for the status and add_comment to report work.",
            inputSchema: .object(properties: [
                ("ticketID", TicketTools.ticketID),
                ("title", .string("New title, one line.")),
                ("description", .string("New description, following the ticket template.")),
                ("priority", TicketTools.priority),
                ("labels", TicketTools.labels),
                ("links", TicketTools.links("The links this ticket declares, replacing the current ones: every link to keep and the new ones; [] removes them all.")),
            ], required: ["ticketID"]),
            permission: .change
        ) { @MainActor arguments throws(ToolError) in
            let id = try arguments.string("ticketID")
            var change = TicketLibrary.TicketChange(title: arguments["title"]?.stringValue, description: arguments["description"]?.stringValue,
                                                    labels: arguments["labels"]?.arrayValue?.compactMap(\.stringValue))
            if let priority = arguments["priority"]?.stringValue { change.priority = .some(TicketFilePriority(rawValue: priority)) }
            if arguments["links"] != nil { change.links = try links(arguments["links"]) }
            try await run { library throws(TicketError) in _ = try await library.update(id, change, by: TicketTools.claude) }
            return try await ticketResult(id)
        }
    }

    var deleteTicket: ToolOperation {
        ToolOperation(
            name: "delete_ticket",
            description: "Delete a ticket and its attachments, moved to the Trash; it is also removed from every bundle and from the links of the other tickets.",
            inputSchema: .object(properties: [("ticketID", TicketTools.ticketID)], required: ["ticketID"]),
            permission: .change
        ) { @MainActor arguments throws(ToolError) in
            let id = try arguments.string("ticketID")
            try await run { library throws(TicketError) in _ = try await library.delete([id]) }
            return [:]
        }
    }

    var setTicketStatus: ToolOperation {
        ToolOperation(
            name: "set_ticket_status",
            description: "Set a ticket's status to todo, in_progress, review or done. Set in_progress when you start working on a ticket, and review or done when you have finished it. Only the user changes a done ticket or a draft.",
            inputSchema: .object(properties: [
                ("ticketID", TicketTools.ticketID),
                ("status", .string("New status.", oneOf: ["todo", "in_progress", "review", "done"])),
            ], required: ["ticketID", "status"]),
            permission: .change
        ) { @MainActor arguments throws(ToolError) in
            let id = try arguments.string("ticketID")
            guard let status = TicketFileStatus(rawValue: try arguments.string("status")), status != .draft else {
                throw ToolError(.invalid, "status: must be one of todo, in_progress, review, done.")
            }
            try await run { library throws(TicketError) in _ = try await library.setStatus(id, to: status, by: TicketTools.claude) }
            return try await ticketResult(id)
        }
    }

    var addComment: ToolOperation {
        ToolOperation(
            name: "add_comment",
            description: "Add a comment by Claude to a ticket, in markdown, optionally with files attached (paths on this Mac: absolute, starting with ~/, or relative to the project's folder).",
            inputSchema: .object(properties: [
                ("ticketID", TicketTools.ticketID),
                ("text", .string("Comment text (markdown).")),
                ("attachments", TicketTools.attachments),
            ], required: ["ticketID", "text"]),
            permission: .change
        ) { @MainActor arguments throws(ToolError) in
            let id = try arguments.string("ticketID")
            let files = try files(arguments["attachments"], in: TicketIDs.parseTicket(id.uppercased())?.project ?? "")
            let text = try arguments.string("text")
            try await run { library throws(TicketError) in _ = try await library.addComment(to: id, text: text, files: files, by: TicketTools.claude) }
            return try await ticketResult(id)
        }
    }

    var updateComment: ToolOperation {
        ToolOperation(
            name: "update_comment",
            description: "Change the text of a comment of a ticket, whoever wrote it. The comment's attached files do not change.",
            inputSchema: .object(properties: [
                ("ticketID", TicketTools.ticketID),
                ("commentID", .string("Comment id (a UUID), from get_ticket.")),
                ("text", .string("New comment text (markdown).")),
            ], required: ["ticketID", "commentID", "text"]),
            permission: .change
        ) { @MainActor arguments throws(ToolError) in
            let id = try arguments.string("ticketID")
            let comment = try uuid(arguments, "commentID", "Comment")
            let text = try arguments.string("text")
            try await run { library throws(TicketError) in _ = try await library.updateComment(comment, of: id, text: text) }
            return try await ticketResult(id)
        }
    }

    var deleteComment: ToolOperation {
        ToolOperation(
            name: "delete_comment",
            description: "Delete a comment of a ticket, whoever wrote it; its attached files are moved to the Trash.",
            inputSchema: .object(properties: [
                ("ticketID", TicketTools.ticketID),
                ("commentID", .string("Comment id (a UUID), from get_ticket.")),
            ], required: ["ticketID", "commentID"]),
            permission: .change
        ) { @MainActor arguments throws(ToolError) in
            let id = try arguments.string("ticketID")
            let comment = try uuid(arguments, "commentID", "Comment")
            try await run { library throws(TicketError) in _ = try await library.deleteComment(comment, of: id) }
            return try await ticketResult(id)
        }
    }

    var removeAttachment: ToolOperation {
        ToolOperation(
            name: "remove_attachment",
            description: "Remove a file attached to a ticket itself (not to one of its comments); the file is moved to the Trash.",
            inputSchema: .object(properties: [
                ("ticketID", TicketTools.ticketID),
                ("attachmentID", .string("Attachment id (a UUID), from get_ticket.")),
            ], required: ["ticketID", "attachmentID"]),
            permission: .change
        ) { @MainActor arguments throws(ToolError) in
            let id = try arguments.string("ticketID")
            let attachment = try uuid(arguments, "attachmentID", "Attachment")
            try await run { library throws(TicketError) in _ = try await library.removeAttachment(attachment, of: id) }
            return try await ticketResult(id)
        }
    }

    // MARK: Bundles

    var listBundles: ToolOperation {
        ToolOperation(
            name: "list_bundles",
            description: "List a project's bundles: named groups of its tickets, in the order they are to be done, each with its status (todo, in_progress, done).",
            inputSchema: .object(properties: [("projectID", TicketTools.projectID)], required: ["projectID"]),
            permission: .read
        ) { @MainActor arguments throws(ToolError) in
            let id = try arguments.string("projectID").uppercased()
            guard projects.snapshot.project(id) != nil else { throw ToolError(.notFound, "Project \(id) not found.") }
            return try encode((try await library().snapshot.bundles[id] ?? []).map(BundleJSON.init))
        }
    }

    var getBundle: ToolOperation {
        ToolOperation(
            name: "get_bundle",
            description: "Get a bundle: title, status, dates, ticket ids in the order they are to be done and chat ids.",
            inputSchema: .object(properties: [("bundleID", TicketTools.bundleID)], required: ["bundleID"]),
            permission: .read
        ) { @MainActor arguments throws(ToolError) in
            try await bundleResult(try arguments.string("bundleID"))
        }
    }

    var createBundle: ToolOperation {
        ToolOperation(
            name: "create_bundle",
            description: "Create a bundle of tickets of one project, in the order they are to be done. Without a title, its title is made of its tickets' titles. A bundle of tickets that are all done starts done.",
            inputSchema: .object(properties: [
                ("projectID", TicketTools.projectID),
                ("ticketIDs", .array("Ids of tickets of the project, in order; at least one.", of: .string())),
                ("title", .string("Bundle title, one line of 1 to 200 characters.")),
            ], required: ["projectID", "ticketIDs"]),
            permission: .change
        ) { @MainActor arguments throws(ToolError) in
            let projectID = try arguments.string("projectID")
            let ids = arguments["ticketIDs"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let library = try library()
            let id: String
            do throws(TicketError) {
                id = try await library.createBundle(in: projectID, title: arguments["title"]?.stringValue ?? "", ticketIDs: ids).id
            } catch {
                throw ticketToolError(error)
            }
            await tickets.refresh()
            return try await bundleResult(id)
        }
    }

    var updateBundle: ToolOperation {
        ToolOperation(
            name: "update_bundle",
            description: "Change a bundle's title or tickets. Omitted arguments are left unchanged; ticketIDs replaces the bundle's tickets and their order.",
            inputSchema: .object(properties: [
                ("bundleID", TicketTools.bundleID),
                ("title", .string("New title, one line.")),
                ("ticketIDs", .array("Ids of tickets of the project, in order, replacing the current ones.", of: .string())),
            ], required: ["bundleID"]),
            permission: .change
        ) { @MainActor arguments throws(ToolError) in
            let id = try arguments.string("bundleID")
            let title = arguments["title"]?.stringValue
            let ids = arguments["ticketIDs"]?.arrayValue?.compactMap(\.stringValue)
            try await run { library throws(TicketError) in _ = try await library.updateBundle(id, title: title, ticketIDs: ids) }
            return try await bundleResult(id)
        }
    }

    var setBundleStatus: ToolOperation {
        ToolOperation(
            name: "set_bundle_status",
            description: "Set a bundle's status to todo or in_progress. A bundle becomes done by itself when all its tickets are done, and only the user changes a done bundle.",
            inputSchema: .object(properties: [
                ("bundleID", TicketTools.bundleID),
                ("status", .string("New status.", oneOf: ["todo", "in_progress"])),
            ], required: ["bundleID", "status"]),
            permission: .change
        ) { @MainActor arguments throws(ToolError) in
            let id = try arguments.string("bundleID")
            guard let status = BundleFile.Status(rawValue: try arguments.string("status")), status != .done else {
                throw ToolError(.invalid, "status: must be one of todo, in_progress.")
            }
            try await run { library throws(TicketError) in _ = try await library.setBundleStatus(id, to: status, by: TicketTools.claude) }
            return try await bundleResult(id)
        }
    }

    var deleteBundle: ToolOperation {
        ToolOperation(
            name: "delete_bundle",
            description: "Delete a bundle; its file is moved to the Trash and its tickets are kept.",
            inputSchema: .object(properties: [("bundleID", TicketTools.bundleID)], required: ["bundleID"]),
            permission: .change
        ) { @MainActor arguments throws(ToolError) in
            let id = try arguments.string("bundleID")
            try await run { library throws(TicketError) in _ = try await library.deleteBundle(id) }
            return [:]
        }
    }

    // MARK: Helpers

    private func library() throws(ToolError) -> TicketLibrary {
        guard let library = tickets.library else { throw ToolError(.unavailable, "The tickets aren't loaded yet.") }
        return library
    }

    /// Runs a change, then shows it in the windows.
    private func run(_ change: (TicketLibrary) async throws(TicketError) -> Void) async throws(ToolError) {
        let library = try library()
        do throws(TicketError) {
            try await change(library)
        } catch {
            throw ticketToolError(error)
        }
        await tickets.refresh()
    }

    private func ticketResult(_ value: String) async throws(ToolError) -> JSONValue {
        let id = value.uppercased()
        guard TicketIDs.parseTicket(id) != nil else { throw ToolError(.invalid, "\"\(value)\" is not a valid ticket id.") }
        guard let ticket = try await library().snapshot.ticket(id) else { throw ToolError(.notFound, "Ticket \(id) not found.") }
        return try encode(json(ticket))
    }

    private func bundleResult(_ value: String) async throws(ToolError) -> JSONValue {
        let id = value.uppercased()
        guard TicketIDs.parseBundle(id) != nil else { throw ToolError(.invalid, "\"\(value)\" is not a valid bundle id.") }
        guard let bundle = try await library().snapshot.bundle(id) else { throw ToolError(.notFound, "Bundle \(id) not found.") }
        return try encode(BundleJSON(bundle))
    }

    private func json(_ ticket: LoadedTicket) -> TicketJSON {
        TicketJSON(ticket, root: projects.snapshot.project(ticket.projectID)?.root)
    }

    private func links(_ value: JSONValue?) throws(ToolError) -> [TicketLinkEntry] {
        try (value?.arrayValue ?? []).map { item throws(ToolError) in
            guard let kind = TicketLinkEntry.Kind(rawValue: try item.string("kind")) else { throw ToolError(.invalid, "links: kind must be dependsOn or related.") }
            return TicketLinkEntry(kind: kind, ticketID: try item.string("ticket"))
        }
    }

    /// Paths as Claude gives them: absolute, `~/`, or relative to the project's folder.
    private func files(_ value: JSONValue?, in projectID: String) throws(ToolError) -> [URL] {
        let root = projects.snapshot.project(projectID.uppercased())?.root
        return (value?.arrayValue ?? []).compactMap(\.stringValue).map { path in
            if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
            if path.hasPrefix("~/") { return URL(fileURLWithPath: NSHomeDirectory() + path.dropFirst()) }
            return URL(fileURLWithPath: root ?? "/").appendingPathComponent(path).standardizedFileURL
        }
    }

    private func uuid(_ arguments: JSONValue, _ name: String, _ what: String) throws(ToolError) -> UUID {
        let value = try arguments.string(name)
        guard let id = UUID(uuidString: value) else { throw ToolError(.notFound, "\(what) \(value) not found.") }
        return id
    }

    private func encode<T: Encodable>(_ value: T) throws(ToolError) -> JSONValue {
        do {
            return try JSONValue(encoding: value)
        } catch {
            throw ToolError(.internal, "The result can't be encoded: \(error).")
        }
    }
}

/// The code of each failure, and V2's message.
func ticketToolError(_ error: TicketError) -> ToolError {
    switch error {
    case .invalid(let message): ToolError(.invalid, message)
    case .notFound(let message): ToolError(.notFound, message)
    case .forbidden(let message): ToolError(.forbidden, message)
    case .storage(.trashFailed): ToolError(.unavailable, error.description)
    case .storage, .project: ToolError(.internal, error.description)
    }
}

/// A ticket in the tools' results: its file's keys, its inverse links, and absolute attachment paths.
struct TicketJSON: Encodable {
    struct Attachment: Encodable {
        let id, name, path, contentType: String
        let size: Int
    }
    struct Comment: Encodable {
        let id, author, created: String
        let updated: String?
        let text: String
        let attachments: [Attachment]
    }
    struct Link: Encodable {
        let kind, ticket: String
    }
    struct History: Encodable {
        let kind, date: String
        let from, to: String?
        let author: String
        let device, chat: String?
    }

    let id, title, status, created, updated, createdBy, description: String
    let priority: String?
    let labels: [String]
    let attachments: [Attachment]
    let comments: [Comment]
    let chats: [String]
    let links: [Link]
    let inverseLinks: [Link]
    let history: [History]

    init(_ loaded: LoadedTicket, root: String?) {
        let file = loaded.file
        func attachment(_ entry: AttachmentEntry) -> Attachment {
            Attachment(id: entry.id.uuidString, name: entry.name, path: root.map { $0 + "/.hephaestus/" + entry.path } ?? entry.path,
                       contentType: entry.contentType, size: entry.size)
        }
        id = file.id
        title = file.title
        status = file.status.rawValue
        created = ISODate.string(from: file.created)
        updated = ISODate.string(from: file.updated)
        createdBy = file.createdBy.rawValue
        description = file.description
        priority = file.priority?.rawValue
        labels = file.labels
        attachments = file.attachments.map(attachment)
        comments = file.comments.map {
            Comment(id: $0.id.uuidString, author: $0.author.rawValue, created: ISODate.string(from: $0.created),
                    updated: $0.updated.map(ISODate.string(from:)), text: $0.text, attachments: $0.attachments.map(attachment))
        }
        chats = file.chatIDs
        links = file.links.map { Link(kind: $0.kind.rawValue, ticket: $0.ticketID) }
        inverseLinks = loaded.inverseLinks.map { Link(kind: $0.kind.rawValue, ticket: $0.ticketID) }
        history = file.history.map {
            History(kind: $0.kind.rawValue, date: ISODate.string(from: $0.date), from: $0.from, to: $0.to, author: $0.author.rawValue,
                    device: $0.device, chat: $0.chat)
        }
    }
}

/// A bundle in the tools' results.
struct BundleJSON: Encodable {
    let id, title, status, created, updated: String
    let tickets: [String]
    let chats: [String]

    init(_ bundle: BundleFile) {
        id = bundle.id
        title = bundle.title
        status = bundle.status.rawValue
        created = ISODate.string(from: bundle.created)
        updated = ISODate.string(from: bundle.updated)
        tickets = bundle.ticketIDs
        chats = bundle.chatIDs
    }
}
