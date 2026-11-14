import FileStorage
import Foundation

/// One element of the key `dashboardWidgets` of the project file: a widget of the project's Dashboard, with
/// its position and size on the grid and its settings (docs/data.md › Dashboard widget).
///
/// V2's format (V2's `DashboardWidget`): the keys `id`, `kind` and `title`, the four position keys while the
/// widget has a stored position, then the keys of its kind only, in the order of the table. A key of another
/// kind is an unknown key of the widget and is kept as read. V3 adds the kind `recentBuilds`, with a `count`,
/// and the status `draft`.
public struct DashboardWidgetEntry: Codable, Sendable, Hashable {
    public var id: UUID
    public var kind: Kind
    /// The `Title` setting; empty means the title of the kind.
    public var title: String
    /// The stored position and size, in cells; all nil while the widget has no stored position. A file
    /// edited by hand may hold only some of them.
    public var column: Int?
    public var row: Int?
    public var width: Int?
    public var height: Int?
    /// `project`: the fields shown.
    public var fields: [Field]
    /// `tickets`: the counts shown.
    public var statuses: [Status]
    /// `tickets` and `cost`: whether the counts or the total include the loaded sub projects.
    public var includeSubprojects: Bool
    /// `recentChats` (V2's): the most chats listed.
    public var chatCount: Int
    /// `recentChats` (V2's): the kinds of the chats listed.
    public var chatKinds: [ChatKind]
    /// `busiestCalls`, `failedRequests` and `recentBuilds` (V3): the most rows listed.
    public var count: Int
    /// The keys neither V2 nor V3 knows for the kind, in the order they were read.
    public var unknownKeys: YAMLMapping

    /// What a widget shows: V2's nine kinds, and V3's `recentBuilds`.
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable {
        case project, tickets, recentChats, cost, instances, serviceGraph, busiestCalls, failedRequests, requestsPerMinute
        /// V3's addition: the project's latest builds.
        case recentBuilds
    }

    /// A field of a `project` widget.
    public enum Field: String, Codable, Sendable, Hashable, CaseIterable {
        case name, identifier, type, folder
    }

    /// A status a `tickets` widget counts: the statuses of the ticket file.
    public enum Status: String, Codable, Sendable, Hashable, CaseIterable {
        /// V3's addition.
        case draft
        case todo
        case inProgress = "in_progress"
        case review
        case done

        /// V2's four, the default of the key.
        public static let v2Statuses: [Status] = [.todo, .inProgress, .review, .done]
    }

    /// A kind of chat a `recentChats` widget lists (V2's).
    public enum ChatKind: String, Codable, Sendable, Hashable, CaseIterable {
        case project, ticket, bundle, feedback
    }

    /// The values of `chatCount` and `count`.
    public static let countRange = 1...20
    /// The most characters of a title, once trimmed.
    public static let titleLimit = 100

    public init(id: UUID, kind: Kind, title: String = "", column: Int? = nil, row: Int? = nil, width: Int? = nil,
                height: Int? = nil, fields: [Field] = Field.allCases, statuses: [Status] = Status.v2Statuses,
                includeSubprojects: Bool = true, chatCount: Int = 5, chatKinds: [ChatKind] = ChatKind.allCases, count: Int = 5,
                unknownKeys: YAMLMapping = [:]) {
        self.id = id
        self.kind = kind
        self.title = title
        self.column = column
        self.row = row
        self.width = width
        self.height = height
        self.fields = fields
        self.statuses = statuses
        self.includeSubprojects = includeSubprojects
        self.chatCount = chatCount
        self.chatKinds = chatKinds
        self.count = count
        self.unknownKeys = unknownKeys
    }

    static let positionKeys = ["column", "row", "width", "height"]

    /// The keys a widget of the kind has after `id`, `kind`, `title` and the position keys, in the order of
    /// the table.
    static func settingKeys(of kind: Kind) -> [String] {
        switch kind {
        case .project: ["fields"]
        case .tickets: ["statuses", "includeSubprojects"]
        case .recentChats: ["chatCount", "chatKinds"]
        case .cost: ["includeSubprojects"]
        case .busiestCalls, .failedRequests, .recentBuilds: ["count"]
        case .instances, .serviceGraph, .requestsPerMinute: []
        }
    }

    static func knownKeys(of kind: Kind) -> Set<String> {
        Set(["id", "kind", "title"] + positionKeys + settingKeys(of: kind))
    }

    public init(from decoder: any Decoder) throws {
        let c = try MappingReader(decoder)
        id = try c.required("id")
        kind = try c.required("kind")
        title = try c.value("title", default: "")
        column = try c.optional("column")
        row = try c.optional("row")
        width = try c.optional("width")
        height = try c.optional("height")
        let keys = Self.settingKeys(of: kind)
        fields = keys.contains("fields") ? try c.value("fields", default: Field.allCases) : Field.allCases
        statuses = keys.contains("statuses") ? try c.value("statuses", default: Status.v2Statuses) : Status.v2Statuses
        includeSubprojects = keys.contains("includeSubprojects") ? try c.value("includeSubprojects", default: true) : true
        chatCount = keys.contains("chatCount") ? try c.value("chatCount", default: 5) : 5
        chatKinds = keys.contains("chatKinds") ? try c.value("chatKinds", default: ChatKind.allCases) : ChatKind.allCases
        count = keys.contains("count") ? try c.value("count", default: 5) : 5
        unknownKeys = try c.unknownKeys(known: Self.knownKeys(of: kind))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = MappingWriter(encoder)
        try c.encode(id, "id")
        try c.encode(kind, "kind")
        try c.encode(title, "title")
        // Left out of the file while the widget has no stored position.
        try c.encodeIfPresent(column, "column")
        try c.encodeIfPresent(row, "row")
        try c.encodeIfPresent(width, "width")
        try c.encodeIfPresent(height, "height")
        for key in Self.settingKeys(of: kind) {
            switch key {
            case "fields": try c.encode(fields, key)
            case "statuses": try c.encode(statuses, key)
            case "includeSubprojects": try c.encode(includeSubprojects, key)
            case "chatCount": try c.encode(chatCount, key)
            case "chatKinds": try c.encode(chatKinds, key)
            default: try c.encode(count, key)
            }
        }
        try c.encodeUnknownKeys(unknownKeys, known: Self.knownKeys(of: kind))
    }

    /// The ids of the list a project without a stored list shows: `00000000-0000-0000-0000-00000000000<n>`
    /// for its n-th widget.
    public static func defaultID(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
    }

    // MARK: Write rules

    /// The write rules of the table; `field` names the widget in the messages, such as
    /// `dashboardWidgets[1]`. Returns the widget with its title trimmed.
    func checked(field: String) throws(ProjectRuleError) -> DashboardWidgetEntry {
        var copy = self
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isNewline), trimmed.count <= Self.titleLimit else {
            throw .widget(field: field, message: "use a title of at most \(Self.titleLimit) characters on one line")
        }
        copy.title = trimmed
        if column != nil || row != nil || width != nil || height != nil {
            guard let column, let row, let width, let height else {
                throw .widget(field: field, message: "give the column, row, width and height together")
            }
            guard (0..<24).contains(column), (1...24).contains(width), column + width <= 24 else {
                throw .widget(field: field, message: "use a column and a width inside the 24 columns")
            }
            guard row >= 0, height >= 1 else {
                throw .widget(field: field, message: "use a row from 0 and a height of at least 1")
            }
        }
        switch kind {
        case .project:
            try Self.checkList(fields, field: field, item: "field")
        case .tickets:
            try Self.checkList(statuses, field: field, item: "status")
        case .recentChats:
            guard Self.countRange.contains(chatCount) else { throw .widget(field: field, message: "use a number of chats from 1 to 20") }
            try Self.checkList(chatKinds, field: field, item: "chat kind")
        case .busiestCalls, .failedRequests, .recentBuilds:
            guard Self.countRange.contains(count) else { throw .widget(field: field, message: "use a number of rows from 1 to 20") }
        case .cost, .instances, .serviceGraph, .requestsPerMinute:
            break
        }
        return copy
    }

    /// A list of checked values: at least one, each once.
    private static func checkList<T: Hashable>(_ values: [T], field: String, item: String) throws(ProjectRuleError) {
        guard !values.isEmpty, Set(values).count == values.count else {
            throw .widget(field: field, message: "use at least one \(item), each once")
        }
    }

    /// The write rules of the key `dashboardWidgets`: each widget the list adds or changes keeps the rules of
    /// the table, in the list's order, then has an id no other widget of the list has. A widget equal to one
    /// of `stored` is written back as it is, also when a file edited by hand made it break a rule; a stored
    /// widget covers as many widgets of the list as the stored list holds, so a copy of it is a widget the
    /// list adds. Returns the list with the titles of the other widgets trimmed.
    public static func checked(_ widgets: [DashboardWidgetEntry], keeping stored: [DashboardWidgetEntry]) throws(ProjectRuleError)
        -> [DashboardWidgetEntry] {
        var unmatched = stored.reduce(into: [DashboardWidgetEntry: Int]()) { $0[$1, default: 0] += 1 }
        let kept = widgets.map { widget in
            guard let count = unmatched[widget], count > 0 else { return false }
            unmatched[widget] = count - 1
            return true
        }
        var list: [DashboardWidgetEntry] = []
        for (index, widget) in widgets.enumerated() {
            list.append(kept[index] ? widget : try widget.checked(field: "dashboardWidgets[\(index)]"))
        }
        for (index, widget) in list.enumerated() where !kept[index] {
            guard !list.indices.contains(where: { $0 != index && list[$0].id == widget.id }) else {
                throw .duplicateWidget(widget.id.uuidString)
            }
        }
        return list
    }
}

/// The key `dashboardGraphWindow`: the time window of the Dashboard's service widgets; absent is `hour`.
public enum DashboardGraphWindow: String, Codable, Sendable, Hashable, CaseIterable {
    case fiveMinutes, hour, day, week
}
