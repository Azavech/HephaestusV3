import FileStorage
import Foundation

/// The ids of tickets and bundles (docs/data.md › Ids): `<IDENT>-<n>` and `<IDENT>-B<n>`.
public enum TicketIDs {
    /// `^[A-Z]{2,8}-[1-9][0-9]*$`: the project's identifier and the number.
    public static func parseTicket(_ value: String) -> (project: String, number: Int)? { split(value, bundle: false) }
    /// `^[A-Z]{2,8}-B[1-9][0-9]*$`.
    public static func parseBundle(_ value: String) -> (project: String, number: Int)? { split(value, bundle: true) }
    public static func ticket(project: String, number: Int) -> String { "\(project)-\(number)" }
    public static func bundle(project: String, number: Int) -> String { "\(project)-B\(number)" }

    private static func split(_ value: String, bundle: Bool) -> (project: String, number: Int)? {
        guard let dash = value.firstIndex(of: "-") else { return nil }
        let project = String(value[..<dash])
        guard (2...8).contains(project.utf8.count), project.utf8.allSatisfy({ (0x41...0x5A).contains($0) }) else { return nil }
        var rest = value[value.index(after: dash)...]
        if bundle {
            guard rest.first == "B" else { return nil }
            rest = rest.dropFirst()
        }
        guard let first = rest.utf8.first, (0x31...0x39).contains(first), rest.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
              let number = Int(rest) else { return nil }
        return (project, number)
    }
}

/// `status` of a ticket file. V2's four values, and V3's `draft`.
public enum TicketFileStatus: String, Codable, Sendable, Hashable, CaseIterable {
    /// V3 addition: written, not yet ready to work on.
    case draft
    case todo
    case inProgress = "in_progress"
    case review
    case done
}

/// Who wrote a ticket or a comment.
public enum Author: String, Codable, Sendable, Hashable {
    case user
    case claude
}

/// V3 addition: how urgent a ticket is.
public enum TicketPriority: String, Codable, Sendable, Hashable, CaseIterable {
    case low, medium, high, urgent
}

/// `.hephaestus/ticket/<TICKET-ID>.yml` (docs/data.md › Ticket file): V2's keys in V2's order, then V3's
/// `priority` and `labels`, each only when set.
public struct TicketFile: Codable, Sendable, Hashable {
    public var schema: Int
    public var id: String
    public var title: String
    public var status: TicketFileStatus
    public var created: Date
    public var updated: Date
    public var createdBy: Author
    /// Markdown.
    public var description: String
    public var attachments: [AttachmentEntry]
    public var comments: [CommentEntry]
    /// The chats linked to the ticket, as V2 wrote them (uppercase UUIDs); kept for the Chat feature.
    public var chatIDs: [String]
    public var links: [TicketLinkEntry]
    public var history: [HistoryEntry]
    public var priority: TicketPriority?
    public var labels: [String]
    public var unknownKeys: YAMLMapping

    public init(id: String, title: String, status: TicketFileStatus = .todo, created: Date, updated: Date? = nil,
                createdBy: Author = .user, description: String = "", attachments: [AttachmentEntry] = [], comments: [CommentEntry] = [],
                chatIDs: [String] = [], links: [TicketLinkEntry] = [], history: [HistoryEntry]? = nil, priority: TicketPriority? = nil,
                labels: [String] = [], unknownKeys: YAMLMapping = [:]) {
        schema = 1
        self.id = id
        self.title = title
        self.status = status
        self.created = created
        self.updated = updated ?? created
        self.createdBy = createdBy
        self.description = description
        self.attachments = attachments
        self.comments = comments
        self.chatIDs = chatIDs
        self.links = links
        self.history = history ?? [HistoryEntry(kind: .created, date: created, to: status.rawValue, author: createdBy == .claude ? .claude : .user)]
        self.priority = priority
        self.labels = labels
        self.unknownKeys = unknownKeys
    }

    static let knownKeys: Set<String> = ["schema", "id", "title", "status", "created", "updated", "createdBy", "description",
                                         "attachments", "comments", "chats", "links", "history", "inverseLinks", "priority", "labels"]

    public init(from decoder: any Decoder) throws {
        let c = try MappingReader(decoder)
        schema = try c.schema()
        id = try c.required("id")
        try c.check("id", id, { TicketIDs.parseTicket($0) != nil }, "ticket id")
        title = try c.required("title")
        status = try c.value("status", default: .todo)
        created = try c.requiredDate("created")
        updated = try c.optionalDate("updated") ?? created
        createdBy = try c.value("createdBy", default: .user)
        description = try c.value("description", default: "")
        attachments = try c.value("attachments", default: [])
        comments = try c.value("comments", default: [])
        chatIDs = try c.value("chats", default: [])
        links = try c.value("links", default: [])
        let read: [HistoryEntry] = try c.value("history", default: [])
        history = read.isEmpty ? [HistoryEntry(kind: .created, date: created, to: TicketFileStatus.todo.rawValue,
                                               author: createdBy == .claude ? .claude : .user)] : read
        priority = try c.optional("priority")
        labels = try c.value("labels", default: [])
        unknownKeys = try c.unknownKeys(known: Self.knownKeys)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = MappingWriter(encoder)
        try c.encode(schema, "schema")
        try c.encode(id, "id")
        try c.encode(title, "title")
        try c.encode(status, "status")
        try c.encodeDate(created, "created")
        try c.encodeDate(updated, "updated")
        try c.encode(createdBy, "createdBy")
        try c.encode(description, "description")
        try c.encode(attachments, "attachments")
        try c.encode(comments, "comments")
        try c.encode(chatIDs, "chats")
        try c.encode(links, "links")
        try c.encode(history, "history")
        try c.encodeIfPresent(priority, "priority")
        if !labels.isEmpty { try c.encode(labels, "labels") }
        try c.encodeUnknownKeys(unknownKeys, known: Self.knownKeys)
    }
}

/// A file stored in `.hephaestus/attachments/<TICKET-ID>/` (docs/data.md › Attachments).
public struct AttachmentEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    /// Relative to `.hephaestus/`: `attachments/<TICKET-ID>/<id>-<name>`.
    public var path: String
    public var contentType: String
    public var size: Int
    public var unknownKeys: YAMLMapping

    public init(id: UUID, name: String, path: String, contentType: String = "application/octet-stream", size: Int = 0) {
        self.id = id
        self.name = name
        self.path = path
        self.contentType = contentType
        self.size = size
        unknownKeys = [:]
    }

    static let knownKeys: Set<String> = ["id", "name", "path", "contentType", "size"]

    public init(from decoder: any Decoder) throws {
        let c = try MappingReader(decoder)
        id = try c.required("id")
        name = try c.required("name")
        path = try c.required("path")
        contentType = try c.value("contentType", default: "application/octet-stream")
        size = try c.value("size", default: 0)
        unknownKeys = try c.unknownKeys(known: Self.knownKeys)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = MappingWriter(encoder)
        try c.encode(id.uuidString, "id")
        try c.encode(name, "name")
        try c.encode(path, "path")
        try c.encode(contentType, "contentType")
        try c.encode(size, "size")
        try c.encodeUnknownKeys(unknownKeys, known: Self.knownKeys)
    }
}

/// A comment of a ticket.
public struct CommentEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var author: Author
    public var created: Date
    /// When the text was last edited; nil when never.
    public var updated: Date?
    /// Markdown.
    public var text: String
    public var attachments: [AttachmentEntry]
    /// For a comment Claude added from a chat: the model and its effort (kept as read).
    public var model: String?
    public var effort: String?
    public var unknownKeys: YAMLMapping

    public init(id: UUID, author: Author, created: Date, text: String, attachments: [AttachmentEntry] = []) {
        self.id = id
        self.author = author
        self.created = created
        self.text = text
        self.attachments = attachments
        unknownKeys = [:]
    }

    static let knownKeys: Set<String> = ["id", "author", "created", "updated", "text", "attachments", "model", "effort", "answer"]

    public init(from decoder: any Decoder) throws {
        let c = try MappingReader(decoder)
        id = try c.required("id")
        author = try c.required("author")
        created = try c.requiredDate("created")
        updated = try c.optionalDate("updated")
        text = try c.value("text", default: "")
        attachments = try c.value("attachments", default: [])
        model = try c.optional("model")
        effort = try c.optional("effort")
        unknownKeys = try c.unknownKeys(known: Self.knownKeys)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = MappingWriter(encoder)
        try c.encode(id.uuidString, "id")
        try c.encode(author, "author")
        try c.encodeDate(created, "created")
        try c.encodeOptionalDate(updated, "updated")
        try c.encode(text, "text")
        try c.encode(attachments, "attachments")
        try c.encodeOptional(model, "model")
        try c.encodeOptional(effort, "effort")
        try c.encodeUnknownKeys(unknownKeys, known: Self.knownKeys)
    }
}

/// A link a ticket declares to another ticket of its project.
public struct TicketLinkEntry: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable {
        case dependsOn
        case related
    }

    public var kind: Kind
    public var ticketID: String
    public var unknownKeys: YAMLMapping

    public init(kind: Kind, ticketID: String) {
        self.kind = kind
        self.ticketID = ticketID
        unknownKeys = [:]
    }

    public init(from decoder: any Decoder) throws {
        let c = try MappingReader(decoder)
        kind = try c.required("kind")
        ticketID = try c.required("ticket")
        try c.check("ticket", ticketID, { TicketIDs.parseTicket($0) != nil }, "ticket id")
        unknownKeys = try c.unknownKeys(known: ["kind", "ticket"])
    }

    public func encode(to encoder: any Encoder) throws {
        var c = MappingWriter(encoder)
        try c.encode(kind, "kind")
        try c.encode(ticketID, "ticket")
        try c.encodeUnknownKeys(unknownKeys, known: ["kind", "ticket"])
    }
}

/// One entry of a ticket's history: its creation, a status change, a rename, a link added or removed, a
/// description edit. Entries are only appended.
public struct HistoryEntry: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable {
        case created, status, title, linkAdded, linkRemoved, description
    }

    public enum HistoryAuthor: String, Codable, Sendable, Hashable {
        case user, claude, automatic
    }

    public var kind: Kind
    public var date: Date
    public var from: String?
    /// The value after the change; nil for `description`.
    public var to: String?
    public var author: HistoryAuthor
    /// The user's Mac, for the author `user`.
    public var device: String?
    /// The chat, for the author `claude`.
    public var chat: String?
    public var unknownKeys: YAMLMapping

    public init(kind: Kind, date: Date, from: String? = nil, to: String? = nil, author: HistoryAuthor, device: String? = nil,
                chat: String? = nil) {
        self.kind = kind
        self.date = date
        self.from = from
        self.to = to
        self.author = author
        self.device = device
        self.chat = chat
        unknownKeys = [:]
    }

    static let knownKeys: Set<String> = ["kind", "date", "from", "to", "author", "device", "chat"]

    public init(from decoder: any Decoder) throws {
        let c = try MappingReader(decoder)
        kind = try c.required("kind")
        date = try c.requiredDate("date")
        from = try c.optional("from")
        to = kind == .description ? nil : try c.required("to", String.self)
        author = try c.required("author")
        device = try c.optional("device")
        chat = try c.optional("chat")
        unknownKeys = try c.unknownKeys(known: Self.knownKeys)
        let statuses = Set(TicketFileStatus.allCases.map(\.rawValue))
        switch kind {
        case .status:
            guard let from, statuses.contains(from), let to, statuses.contains(to) else {
                throw c.invalid("to", "a status entry needs two statuses")
            }
        case .title:
            guard from != nil else { throw c.invalid("from", "a title entry needs the previous title") }
        case .created:
            guard let to, statuses.contains(to) else { throw c.invalid("to", "\"\(to ?? "")\" is not a status") }
        case .linkAdded, .linkRemoved:
            let parts = (to ?? "").split(separator: " ")
            guard parts.count == 2, TicketLinkEntry.Kind(rawValue: String(parts[0])) != nil,
                  TicketIDs.parseTicket(String(parts[1])) != nil else { throw c.invalid("to", "a link entry needs <kind> <ticket id>") }
        case .description:
            break
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = MappingWriter(encoder)
        try c.encode(kind, "kind")
        try c.encodeDate(date, "date")
        try c.encodeOptional(from, "from")
        if kind != .description { try c.encodeOptional(to, "to") }
        try c.encode(author, "author")
        try c.encodeOptional(device, "device")
        try c.encodeOptional(chat, "chat")
        try c.encodeUnknownKeys(unknownKeys, known: Self.knownKeys)
    }
}

/// `.hephaestus/bundle/<BUNDLE-ID>.yml` (docs/data.md › Bundle file).
public struct BundleFile: Codable, Sendable, Hashable {
    public enum Status: String, Codable, Sendable, Hashable, CaseIterable {
        case todo
        case inProgress = "in_progress"
        case done
    }

    public var schema: Int
    public var id: String
    public var title: String
    public var status: Status
    public var created: Date
    public var updated: Date
    /// Tickets of the project in implementation order, without duplicates.
    public var ticketIDs: [String]
    public var chatIDs: [String]
    public var unknownKeys: YAMLMapping

    public init(id: String, title: String, status: Status = .todo, created: Date, ticketIDs: [String] = []) {
        schema = 1
        self.id = id
        self.title = title
        self.status = status
        self.created = created
        updated = created
        self.ticketIDs = ticketIDs
        chatIDs = []
        unknownKeys = [:]
    }

    static let knownKeys: Set<String> = ["schema", "id", "title", "status", "created", "updated", "tickets", "chats"]

    public init(from decoder: any Decoder) throws {
        let c = try MappingReader(decoder)
        schema = try c.schema()
        id = try c.required("id")
        try c.check("id", id, { TicketIDs.parseBundle($0) != nil }, "bundle id")
        title = try c.required("title")
        status = try c.value("status", default: .todo)
        created = try c.requiredDate("created")
        updated = try c.optionalDate("updated") ?? created
        ticketIDs = try c.value("tickets", default: [])
        chatIDs = try c.value("chats", default: [])
        unknownKeys = try c.unknownKeys(known: Self.knownKeys)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = MappingWriter(encoder)
        try c.encode(schema, "schema")
        try c.encode(id, "id")
        try c.encode(title, "title")
        try c.encode(status, "status")
        try c.encodeDate(created, "created")
        try c.encodeDate(updated, "updated")
        try c.encode(ticketIDs, "tickets")
        try c.encode(chatIDs, "chats")
        try c.encodeUnknownKeys(unknownKeys, known: Self.knownKeys)
    }
}
