import FileStorage
import Foundation
import MCPKit
import ProjectData
import TicketData
import ToolsFoundation

/// The feedback chats, as `create_ticket` needs them: the first ticket a feedback chat's Claude creates lists the
/// chat in its `chats`, and the chat records it as its ticket (docs/ui/chat.md › Feedback).
public struct FeedbackLink {
    /// Whether the chat is a feedback chat without its ticket yet.
    public let isUnlinked: @MainActor (String) -> Bool
    /// Records the ticket as the chat's.
    public let link: @MainActor (String, String) -> Void

    public init(isUnlinked: @escaping @MainActor (String) -> Bool, link: @escaping @MainActor (String, String) -> Void) {
        self.isUnlinked = isUnlinked
        self.link = link
    }
}

/// The ticket and bundle operations the MCP server offers Claude (docs/mcp.md › Ticket tools): the same
/// library the Tickets window changes, as Claude, with the rules for Claude.
public enum TicketTools {
    /// The ticket tools, then the bundle tools, in the order of docs/mcp.md. `feedback` links the first ticket a
    /// feedback chat's Claude creates to that chat.
    @MainActor
    public static func operations(tickets: TicketSession, projects: ProjectSession, feedback: FeedbackLink? = nil,
                                  replyModel: @escaping @MainActor (String) -> (model: String, effort: String?)? = { _ in nil }) -> [ToolOperation] {
        var tools = TicketToolSet(tickets: tickets, projects: projects, feedback: feedback)
        tools.replyModel = replyModel
        return [tools.listTickets, tools.getTicket, tools.getAttachment, tools.createTicket, tools.updateTicket, tools.deleteTicket, tools.setTicketStatus,
                tools.addComment, tools.updateComment, tools.deleteComment, tools.removeAttachment,
                tools.listBundles, tools.getBundle, tools.createBundle, tools.updateBundle, tools.setBundleStatus, tools.deleteBundle]
    }

    /// Claude: in the chat whose token made the call, or `external` with the external token.
    static var claude: TicketActor { .claude(chat: MCPCaller.current.chatID ?? "external") }
    static let projectID = ToolSchema.string("Project identifier, 2 to 8 letters, such as ORD.")
    static let ticketID = ToolSchema.string("Ticket id, such as ORD-12.")
    static let bundleID = ToolSchema.string("Bundle id, such as ORD-B2.")
    static let attachments = ToolSchema.array("Files on this Mac to copy in, each an absolute path, a path from ~/, or a path within the project's folder.", of: .string())
    static let priority = ToolSchema.string("low, medium, high or urgent; empty to clear it.", oneOf: ["", "low", "medium", "high", "urgent"])
    static let labels = ToolSchema.array("The labels, replacing the current ones; [] clears them.", of: .string())
    static func links(_ description: String) -> ToolSchema {
        .array(description, of: .object(properties: [
            ("kind", .string("dependsOn: this ticket waits for the other one to be done. related: a plain link.", oneOf: ["dependsOn", "related"])),
            ("ticket", .string("Id of a ticket in the same project, such as ORD-15.")),
        ], required: ["kind", "ticket"]))
    }
}

/// The operations, over one ticket session and its projects.
@MainActor
private struct TicketToolSet {
    let tickets: TicketSession
    let projects: ProjectSession
    let feedback: FeedbackLink?
    /// The model and effort of a chat's latest reply, by chat id: a comment Claude adds keeps them.
    var replyModel: @MainActor (String) -> (model: String, effort: String?)? = { _ in nil }

    init(tickets: TicketSession, projects: ProjectSession, feedback: FeedbackLink?) {
        self.tickets = tickets
        self.projects = projects
        self.feedback = feedback
    }
}

extension TicketToolSet {
    // MARK: Tickets

    var listTickets: ToolOperation {
        ToolOperation(
            name: "list_tickets",
            description: "Returns a project's tickets, its sub projects' included. With status, only the tickets in that status.",
            inputSchema: .object(properties: [
                ("projectID", TicketTools.projectID),
                ("status", .string("draft, todo, in_progress, review or done.", oneOf: ["draft", "todo", "in_progress", "review", "done"])),
            ], required: ["projectID"]),
            permission: .read,
            describe: TicketTools.describe("list_tickets")
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
            description: "Returns a ticket: title, status, priority, labels, dates, creator, description, attachments with absolute paths, comments, chat ids, links and history. links holds the links written in this ticket (dependsOn, related); inverseLinks holds the links written in other tickets that point here (blocks, related). history records the creation, status changes, renames, link changes and description edits, each with its author and date.",
            inputSchema: .object(properties: [("ticketID", TicketTools.ticketID)], required: ["ticketID"]),
            permission: .read,
            describe: TicketTools.describe("get_ticket")
        ) { @MainActor arguments throws(ToolError) in
            try await ticketResult(try arguments.string("ticketID"))
        }
    }

    var getAttachment: ToolOperation {
        ToolOperation(
            name: "get_attachment",
            description: "Returns a file attached to a ticket or to one of its comments. An image (PNG, JPEG, HEIC, GIF, TIFF…) comes as an image, scaled down to 1568 pixels on its longest side when larger. A UTF-8 text comes as JSON with name, contentType, text and truncated, cut after 256 KB. Any other file is refused, with its path.",
            inputSchema: .object(properties: [
                ("ticketID", TicketTools.ticketID),
                ("attachmentID", .string("The attachment's UUID, as get_ticket returns it.")),
            ], required: ["ticketID", "attachmentID"]),
            permission: .read,
            describe: TicketTools.describe("get_attachment")
        ) { @MainActor arguments throws(ToolError) in
            let value = try arguments.string("ticketID")
            let id = value.uppercased()
            guard TicketIDs.parseTicket(id) != nil else { throw ToolError(.invalid, "\"\(value)\" is not a valid ticket id.") }
            let attachment = try uuid(arguments, "attachmentID", "Attachment")
            guard let ticket = try await library().snapshot.ticket(id) else { throw ToolError(.notFound, "Ticket \(id) not found.") }
            let entries = ticket.file.attachments + ticket.file.comments.flatMap(\.attachments)
            guard let entry = entries.first(where: { $0.id == attachment }) else {
                throw ToolError(.notFound, "Attachment \(attachment.uuidString) not found.")
            }
            guard let root = projects.snapshot.project(ticket.projectID)?.root else {
                throw ToolError(.unavailable, "The project of \(id) isn't loaded.")
            }
            let url = URL(fileURLWithPath: root + "/.hephaestus/" + entry.path)
            // Reading and scaling a large image takes a moment: off the main actor.
            let name = entry.name
            let contentType = entry.contentType
            let result = await Task.detached { () -> Result<JSONValue, ToolError> in
                do throws(ToolError) {
                    return .success(try AttachmentContent.read(url, name: name, contentType: contentType))
                } catch {
                    return .failure(error)
                }
            }.value
            return try result.get()
        }
    }

    var createTicket: ToolOperation {
        ToolOperation(
            name: "create_ticket",
            description: "Creates a ticket by Claude in a project, with the status todo. Without a title, the description's first line that is neither empty nor a heading becomes the title. The files listed in attachments are copied into the ticket.",
            inputSchema: .object(properties: [
                ("projectID", TicketTools.projectID),
                ("title", .string("One line of 1 to 200 characters.")),
                ("description", .string("The description, in Markdown.")),
                ("priority", TicketTools.priority),
                ("labels", TicketTools.labels),
                ("attachments", TicketTools.attachments),
                ("links", TicketTools.links("Links to tickets in the same project.")),
            ], required: ["projectID", "description"]),
            permission: .changeTickets,
            describe: TicketTools.describe("create_ticket")
        ) { @MainActor arguments throws(ToolError) in
            let projectID = try arguments.string("projectID").uppercased()
            // A feedback chat's first ticket lists the chat, and the chat records it (V2's feedback link).
            let linked = MCPCaller.current.chatID.flatMap { chat in feedback?.isUnlinked(chat) == true ? chat : nil }
            let request = TicketLibrary.NewTicket(
                projectID: projectID, title: arguments["title"]?.stringValue ?? "", description: try arguments.string("description"),
                priority: arguments["priority"]?.stringValue.flatMap(TicketFilePriority.init(rawValue:)),
                labels: arguments["labels"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                links: try links(arguments["links"]), attachments: try files(arguments["attachments"], in: projectID),
                chats: linked.map { [$0] } ?? []
            )
            let library = try library()
            let id: String
            do throws(TicketError) {
                id = try await library.create(request, by: TicketTools.claude).id
            } catch {
                throw ticketToolError(error)
            }
            if let linked {
                feedback?.link(linked, id)
            }
            await tickets.refresh()
            return try await ticketResult(id)
        }
    }

    var updateTicket: ToolOperation {
        ToolOperation(
            name: "update_ticket",
            description: "Changes a ticket's title, description, priority, labels or links. Arguments left out keep their value.",
            inputSchema: .object(properties: [
                ("ticketID", TicketTools.ticketID),
                ("title", .string("The new title, one line of 1 to 200 characters.")),
                ("description", .string("The new description, in Markdown.")),
                ("priority", TicketTools.priority),
                ("labels", TicketTools.labels),
                ("links", TicketTools.links("Every link the ticket declares after the change; links missing from the list are removed, and [] removes them all.")),
            ], required: ["ticketID"]),
            permission: .changeTickets,
            describe: TicketTools.describe("update_ticket")
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
            description: "Deletes a ticket, moving its file and attachments to the Trash, and takes it out of every bundle and every other ticket's links.",
            inputSchema: .object(properties: [("ticketID", TicketTools.ticketID)], required: ["ticketID"]),
            permission: .deleteTickets,
            describe: TicketTools.describe("delete_ticket")
        ) { @MainActor arguments throws(ToolError) in
            let id = try arguments.string("ticketID")
            try await run { library throws(TicketError) in _ = try await library.delete([id]) }
            return [:]
        }
    }

    var setTicketStatus: ToolOperation {
        ToolOperation(
            name: "set_ticket_status",
            description: "Changes a ticket's status to todo, in_progress, review or done. Drafts and done tickets can only be changed by the user.",
            inputSchema: .object(properties: [
                ("ticketID", TicketTools.ticketID),
                ("status", .string("New status.", oneOf: ["todo", "in_progress", "review", "done"])),
            ], required: ["ticketID", "status"]),
            permission: .changeTickets,
            describe: TicketTools.describe("set_ticket_status")
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
            description: "Adds a comment by Claude to a ticket, with optional files copied in.",
            inputSchema: .object(properties: [
                ("ticketID", TicketTools.ticketID),
                ("text", .string("The comment, in Markdown.")),
                ("attachments", TicketTools.attachments),
            ], required: ["ticketID", "text"]),
            permission: .changeTickets,
            describe: TicketTools.describe("add_comment")
        ) { @MainActor arguments throws(ToolError) in
            let id = try arguments.string("ticketID")
            let files = try files(arguments["attachments"], in: TicketIDs.parseTicket(id.uppercased())?.project ?? "")
            let text = try arguments.string("text")
            let reply = MCPCaller.current.chatID.flatMap(replyModel)
            try await run { library throws(TicketError) in
                _ = try await library.addComment(to: id, text: text, files: files, by: TicketTools.claude, model: reply?.model, effort: reply?.effort)
            }
            return try await ticketResult(id)
        }
    }

    var updateComment: ToolOperation {
        ToolOperation(
            name: "update_comment",
            description: "Replaces the text of a ticket's comment, whoever wrote it. Its files stay as they are.",
            inputSchema: .object(properties: [
                ("ticketID", TicketTools.ticketID),
                ("commentID", .string("The comment's UUID, as get_ticket returns it.")),
                ("text", .string("The new text, in Markdown.")),
            ], required: ["ticketID", "commentID", "text"]),
            permission: .changeTickets,
            describe: TicketTools.describe("update_comment")
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
            description: "Deletes a ticket's comment, whoever wrote it, and moves its files to the Trash.",
            inputSchema: .object(properties: [
                ("ticketID", TicketTools.ticketID),
                ("commentID", .string("The comment's UUID, as get_ticket returns it.")),
            ], required: ["ticketID", "commentID"]),
            permission: .deleteTickets,
            describe: TicketTools.describe("delete_comment")
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
            description: "Removes a file attached to the ticket itself, not to a comment, and moves it to the Trash.",
            inputSchema: .object(properties: [
                ("ticketID", TicketTools.ticketID),
                ("attachmentID", .string("The attachment's UUID, as get_ticket returns it.")),
            ], required: ["ticketID", "attachmentID"]),
            permission: .deleteTickets,
            describe: TicketTools.describe("remove_attachment")
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
            description: "Returns a project's bundles: ordered groups of its tickets, each with the status todo, in_progress or done.",
            inputSchema: .object(properties: [("projectID", TicketTools.projectID)], required: ["projectID"]),
            permission: .read,
            describe: TicketTools.describe("list_bundles")
        ) { @MainActor arguments throws(ToolError) in
            let id = try arguments.string("projectID").uppercased()
            guard projects.snapshot.project(id) != nil else { throw ToolError(.notFound, "Project \(id) not found.") }
            return try encode((try await library().snapshot.bundles[id] ?? []).map(BundleJSON.init))
        }
    }

    var getBundle: ToolOperation {
        ToolOperation(
            name: "get_bundle",
            description: "Returns a bundle: title, status, dates, its ticket ids in order, and chat ids.",
            inputSchema: .object(properties: [("bundleID", TicketTools.bundleID)], required: ["bundleID"]),
            permission: .read,
            describe: TicketTools.describe("get_bundle")
        ) { @MainActor arguments throws(ToolError) in
            try await bundleResult(try arguments.string("bundleID"))
        }
    }

    var createBundle: ToolOperation {
        ToolOperation(
            name: "create_bundle",
            description: "Creates a bundle from tickets of one project, kept in the order given. Without a title, it is named after its tickets. When every ticket is already done, the bundle starts done.",
            inputSchema: .object(properties: [
                ("projectID", TicketTools.projectID),
                ("ticketIDs", .array("Ids of the project's tickets, in order; one at least.", of: .string())),
                ("title", .string("One line of 1 to 200 characters.")),
            ], required: ["projectID", "ticketIDs"]),
            permission: .changeTickets,
            describe: TicketTools.describe("create_bundle")
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
            description: "Changes a bundle's title or tickets. Arguments left out keep their value.",
            inputSchema: .object(properties: [
                ("bundleID", TicketTools.bundleID),
                ("title", .string("The new title, one line of 1 to 200 characters.")),
                ("ticketIDs", .array("Ids of the project's tickets, in order, replacing the whole list.", of: .string())),
            ], required: ["bundleID"]),
            permission: .changeTickets,
            describe: TicketTools.describe("update_bundle")
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
            description: "Changes a bundle's status to todo or in_progress. A bundle turns done on its own once all its tickets are done, and a done bundle can only be changed by the user.",
            inputSchema: .object(properties: [
                ("bundleID", TicketTools.bundleID),
                ("status", .string("New status.", oneOf: ["todo", "in_progress"])),
            ], required: ["bundleID", "status"]),
            permission: .changeTickets,
            describe: TicketTools.describe("set_bundle_status")
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
            description: "Deletes a bundle, moving its file to the Trash; its tickets stay.",
            inputSchema: .object(properties: [("bundleID", TicketTools.bundleID)], required: ["bundleID"]),
            permission: .deleteTickets,
            describe: TicketTools.describe("delete_bundle")
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

    /// Paths as Claude gives them: absolute, `~` or `~/`, or relative to the project's folder.
    private func files(_ value: JSONValue?, in projectID: String) throws(ToolError) -> [URL] {
        let root = projects.snapshot.project(projectID.uppercased())?.root
        return (value?.arrayValue ?? []).compactMap(\.stringValue).map { path in
            if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
            if path == "~" { return URL(fileURLWithPath: NSHomeDirectory()) }
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

/// The code of each failure, and its message.
func ticketToolError(_ error: TicketError) -> ToolError {
    switch error {
    case .invalid(let message): ToolError(.invalid, message)
    case .notFound(let message): ToolError(.notFound, message)
    case .forbidden(let message): ToolError(.forbidden, message)
    case .conflict(let message): ToolError(.conflict, message)
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

// MARK: Chat

extension TicketTools {
    /// How a chat shows a call of the tool `name` (docs/ui/chat.md › Tool-call rows): what it did, and for a
    /// change, the card's sentence and what it would write.
    static func describe(_ name: String) -> @Sendable (JSONValue) -> ToolCallText {
        { arguments in text(name, arguments) }
    }

    nonisolated static func text(_ name: String, _ arguments: JSONValue) -> ToolCallText {
        func value(_ key: String) -> String { arguments[key]?.stringValue ?? "" }
        let ticket = value("ticketID").uppercased()
        let bundle = value("bundleID").uppercased()
        let project = name.contains("bundle") && !bundle.isEmpty ? prefix(bundle) : (ticket.isEmpty ? value("projectID").uppercased() : prefix(ticket))
        let list = ToolItem(tool: "tickets", projectID: project, focus: "", title: project)
        let ticketItem = ToolItem(tool: "tickets", projectID: project, focus: ticket, title: ticket)
        let bundleItem = ToolItem(tool: "tickets", projectID: project, focus: bundle, title: bundle)
        let status = statusTitle(value("status"))
        switch name {
        case "list_tickets":
            return ToolCallText(action: String(localized: "Listed the tickets of \(project)", bundle: #bundle), item: list)
        case "get_ticket":
            return ToolCallText(action: String(localized: "Read ticket \(ticket)", bundle: #bundle), item: ticketItem)
        case "get_attachment":
            return ToolCallText(action: String(localized: "Read an attachment of \(ticket)", bundle: #bundle), item: ticketItem)
        case "create_ticket":
            let preview = [value("title"), value("description")].filter { !$0.isEmpty }.joined(separator: "\n\n")
            return ToolCallText(action: String(localized: "Created a ticket in \(project)", bundle: #bundle),
                                request: String(localized: "Claude wants to create a ticket in \(project)", bundle: #bundle),
                                preview: preview, item: list)
        case "update_ticket":
            var lines: [String] = []
            if let title = arguments["title"]?.stringValue { lines.append(String(localized: "Title: \(title)", bundle: #bundle)) }
            if let priority = arguments["priority"]?.stringValue {
                lines.append(String(localized: "Priority: \(priority.isEmpty ? "—" : priority)", bundle: #bundle))
            }
            if let labels = arguments["labels"]?.arrayValue {
                lines.append(String(localized: "Labels: \(labels.compactMap(\.stringValue).joined(separator: ", "))", bundle: #bundle))
            }
            if let description = arguments["description"]?.stringValue { lines.append(description) }
            return ToolCallText(action: String(localized: "Changed \(ticket)", bundle: #bundle),
                                request: String(localized: "Claude wants to change \(ticket)", bundle: #bundle),
                                preview: lines.isEmpty ? nil : lines.joined(separator: "\n"), item: ticketItem)
        case "delete_ticket":
            return ToolCallText(action: String(localized: "Deleted \(ticket)", bundle: #bundle),
                                request: String(localized: "Claude wants to delete \(ticket)", bundle: #bundle), item: ticketItem)
        case "set_ticket_status":
            return ToolCallText(action: String(localized: "Moved \(ticket) to \(status)", bundle: #bundle),
                                request: String(localized: "Claude wants to move \(ticket) to \(status)", bundle: #bundle), item: ticketItem)
        case "add_comment":
            return ToolCallText(action: String(localized: "Commented on \(ticket)", bundle: #bundle),
                                request: String(localized: "Claude wants to comment on \(ticket)", bundle: #bundle),
                                preview: value("text"), item: ticketItem)
        case "update_comment":
            return ToolCallText(action: String(localized: "Changed a comment on \(ticket)", bundle: #bundle),
                                request: String(localized: "Claude wants to change a comment on \(ticket)", bundle: #bundle),
                                preview: value("text"), item: ticketItem)
        case "delete_comment":
            return ToolCallText(action: String(localized: "Deleted a comment on \(ticket)", bundle: #bundle),
                                request: String(localized: "Claude wants to delete a comment on \(ticket)", bundle: #bundle), item: ticketItem)
        case "remove_attachment":
            return ToolCallText(action: String(localized: "Removed an attachment from \(ticket)", bundle: #bundle),
                                request: String(localized: "Claude wants to remove an attachment from \(ticket)", bundle: #bundle), item: ticketItem)
        case "list_bundles":
            return ToolCallText(action: String(localized: "Listed the bundles of \(project)", bundle: #bundle), item: list)
        case "get_bundle":
            return ToolCallText(action: String(localized: "Read bundle \(bundle)", bundle: #bundle), item: bundleItem)
        case "create_bundle":
            let tickets = (arguments["ticketIDs"]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: ", ")
            return ToolCallText(action: String(localized: "Created a bundle in \(project)", bundle: #bundle),
                                request: String(localized: "Claude wants to create a bundle in \(project)", bundle: #bundle),
                                preview: [value("title"), tickets].filter { !$0.isEmpty }.joined(separator: "\n"), item: list)
        case "update_bundle":
            let tickets = (arguments["ticketIDs"]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: ", ")
            return ToolCallText(action: String(localized: "Changed bundle \(bundle)", bundle: #bundle),
                                request: String(localized: "Claude wants to change bundle \(bundle)", bundle: #bundle),
                                preview: [value("title"), tickets].filter { !$0.isEmpty }.joined(separator: "\n"), item: bundleItem)
        case "set_bundle_status":
            return ToolCallText(action: String(localized: "Moved bundle \(bundle) to \(status)", bundle: #bundle),
                                request: String(localized: "Claude wants to move bundle \(bundle) to \(status)", bundle: #bundle), item: bundleItem)
        case "delete_bundle":
            return ToolCallText(action: String(localized: "Deleted bundle \(bundle)", bundle: #bundle),
                                request: String(localized: "Claude wants to delete bundle \(bundle)", bundle: #bundle), item: bundleItem)
        default:
            return ToolCallText(action: name)
        }
    }

    /// `ORD` of `ORD-142` or `ORD-B2`.
    nonisolated static func prefix(_ id: String) -> String {
        String(id.split(separator: "-", maxSplits: 1).first ?? "")
    }

    nonisolated static func statusTitle(_ status: String) -> String {
        switch status {
        case "draft": String(localized: "Draft", bundle: #bundle, comment: "A ticket's status")
        case "todo": String(localized: "To Do", bundle: #bundle, comment: "A ticket's status")
        case "in_progress": String(localized: "In Progress", bundle: #bundle, comment: "A ticket's status")
        case "review": String(localized: "In Review", bundle: #bundle, comment: "A ticket's status")
        case "done": String(localized: "Done", bundle: #bundle, comment: "A ticket's status")
        default: status
        }
    }
}
