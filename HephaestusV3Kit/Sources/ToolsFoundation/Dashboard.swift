import Foundation

// The Dashboard's model (docs/ui/dashboard.md): the grid, its placement rule, and the widgets of the tools. It lives here, beside the other shared values,
// because each tool draws its own widgets from it.

/// A widget of a project's Dashboard, with its position, its size and its settings
/// (docs/ui/dashboard.md › Grid, Widgets and Settings).
///
/// Every setting has a property, but a widget reads only those of its kind.
nonisolated public struct DashboardWidget: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var kind: DashboardWidgetKind
    /// The `Title` setting; empty means the title of the kind.
    public var title: String
    /// The stored position and size, counted in cells: the first column and the first row the
    /// widget covers, then the columns and the rows it covers. The four are nil while the widget
    /// has no stored position.
    public var column: Int?
    public var row: Int?
    public var width: Int?
    public var height: Int?
    /// Project widgets: the fields shown.
    public var fields: [DashboardProjectField]
    /// Tickets widgets: the counts shown.
    public var statuses: [TicketStatus]
    /// Tickets widgets: whether the counts include the sub projects' tickets.
    public var includeSubprojects: Bool
    /// Recent Builds, Busiest Calls and Failed Requests widgets: the most rows listed, 1–20.
    public var count: Int

    /// The values of `count` the settings offer.
    public static let countRange = 1...20
    /// The most characters of a title, once trimmed.
    public static let titleLimit = 100

    public init(
        id: UUID = UUID(), kind: DashboardWidgetKind, title: String = "",
        column: Int? = nil, row: Int? = nil, width: Int? = nil, height: Int? = nil,
        fields: [DashboardProjectField] = DashboardProjectField.allCases, statuses: [TicketStatus] = TicketStatus.allCases,
        includeSubprojects: Bool = true, count: Int = 5
    ) {
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
        self.count = count
    }

    /// The stored position and size, brought back inside the grid; nil for a widget without
    /// position, which has none of the four or only some of them (docs/ui/dashboard.md › Placement).
    public var cells: DashboardCells? {
        get {
            guard let column, let row, let width, let height else { return nil }
            return DashboardGrid.clamped(DashboardCells(column: column, row: row, width: width, height: height))
        }
        set {
            column = newValue?.column
            row = newValue?.row
            width = newValue?.width
            height = newValue?.height
        }
    }

    /// The list a project without a stored list shows, with fixed ids, an empty title, no stored
    /// position and the default settings: Project and Tickets, then Recent Builds in place of
    /// its Recent Chats, and the Service Graph for a project whose map can be read.
    public static func defaultList(for project: Project) -> [DashboardWidget] {
        let kinds: [DashboardWidgetKind] = [.project, .tickets, .recentBuilds] + (DashboardWidgetKind.hasServiceMap(project) ? [.serviceGraph] : [])
        return kinds.enumerated().map { index, kind in
            DashboardWidget(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!, kind: kind)
        }
    }
}

/// The cells a widget covers on the grid of the Dashboard: its position and its size
/// (docs/ui/dashboard.md › Grid).
nonisolated public struct DashboardCells: Sendable, Hashable {
    /// The first column, 0–23 from the left.
    public var column: Int
    /// The first row, 0 or more from the top.
    public var row: Int
    /// The columns covered, 1–24.
    public var width: Int
    /// The rows covered, 1 or more.
    public var height: Int

    public init(column: Int, row: Int, width: Int, height: Int) {
        self.column = column
        self.row = row
        self.width = width
        self.height = height
    }

    /// The first row under the widget.
    public var bottom: Int { row + height }

    /// Whether the two widgets cover a same cell.
    public func overlaps(_ other: DashboardCells) -> Bool {
        column < other.column + other.width && other.column < column + width && row < other.bottom && other.row < bottom
    }
}

/// The grid of the Dashboard and the place of the widgets on it (docs/ui/dashboard.md › Grid,
/// Placement and Lists without positions).
nonisolated public enum DashboardGrid {
    /// The columns of the grid.
    public static let columns = 24
    /// The columns of a widget without position and of an added widget: half the grid.
    public static let halfWidth = 12
    /// The largest row and the largest height the Dashboard counts for a stored position, so that
    /// a value written by hand never overflows.
    public static let rowLimit = 100_000
    /// The largest row the placement starts from: far above any row it computes from stored rows
    /// and heights, and far enough from `Int.max` for the rows it adds.
    static let rowBound = Int.max / 2

    /// A position brought back inside the grid: a width within 1–24, a column that keeps the
    /// widget inside the 24 columns, a row from 0 and a height from 1, both up to `rowLimit`.
    public static func clamped(_ cells: DashboardCells) -> DashboardCells {
        let width = min(max(cells.width, 1), columns)
        return DashboardCells(column: min(max(cells.column, 0), columns - width), row: min(max(cells.row, 0), rowLimit),
                              width: width, height: min(max(cells.height, 1), rowLimit))
    }

    /// The placement rule: the widgets are taken in order of row, then of column, those with the
    /// same row and column in the order of `cells`; each one moves down below any widget placed
    /// before it that it overlaps, then rises as far as it can without overlapping one, up to
    /// row 0. `first` is the widget the user moves or resizes, placed before the other widgets
    /// that start on its row (docs/ui/dashboard.md › Edit mode).
    public static func placed(_ cells: [DashboardCells], first: Int? = nil) -> [DashboardCells] {
        // A row computed by a layout, under widgets stored at the row limit, can be beyond that
        // limit: it is kept, so that it stays in its order.
        var result = cells.map { cell -> DashboardCells in
            var inside = clamped(cell)
            inside.row = min(max(cell.row, 0), rowBound)
            return inside
        }
        let order = result.indices.sorted { a, b in
            if result[a].row != result[b].row { return result[a].row < result[b].row }
            if (a == first) != (b == first) { return a == first }
            if result[a].column != result[b].column { return result[a].column < result[b].column }
            return a < b
        }
        var placed: [DashboardCells] = []
        for index in order {
            var cell = result[index]
            while let below = placed.filter({ $0.overlaps(cell) }).map(\.bottom).max() {
                cell.row = below
            }
            // Nothing overlaps it now, so the widgets of its columns are above it or under it: it
            // rises up to the lowest of those above.
            cell.row = placed.filter { $0.column < cell.column + cell.width && cell.column < $0.column + $0.width && $0.bottom <= cell.row }
                .map(\.bottom).max() ?? 0
            placed.append(cell)
            result[index] = cell
        }
        return result
    }

    /// The cells of each widget of a list, nil for a widget of a kind the Dashboard doesn't show
    /// (`DashboardWidgetKind.isShown`), which takes no place. A widget with a stored position starts from it; the widgets
    /// without position are taken in list order, two per row at columns 0 and 12, each 12 columns
    /// wide and `rows` high, the first pair under every widget that has a stored position and each
    /// pair under the previous one; then the placement rule applies to all of them. `rows` gives the
    /// rows the content of the widget at an index needs, at the cell size of the window.
    public static func layout(of widgets: [DashboardWidget], shown kinds: Set<DashboardWidgetKind>, rows: (Int) -> Int) -> [DashboardCells?] {
        let shown = widgets.indices.filter { kinds.contains(widgets[$0].kind) }
        var cells: [Int: DashboardCells] = [:]
        for index in shown {
            cells[index] = widgets[index].cells
        }
        var top = cells.values.map(\.bottom).max() ?? 0
        let free = shown.filter { cells[$0] == nil }
        for start in stride(from: 0, to: free.count, by: 2) {
            var bottom = top
            for (offset, index) in free[start..<min(start + 2, free.count)].enumerated() {
                let height = min(max(rows(index), 1), rowLimit)
                cells[index] = DashboardCells(column: offset * halfWidth, row: top, width: halfWidth, height: height)
                bottom = max(bottom, top + height)
            }
            top = bottom
        }
        let placed = Self.placed(shown.compactMap { cells[$0] })
        var result = [DashboardCells?](repeating: nil, count: widgets.count)
        for (offset, index) in shown.enumerated() {
            result[index] = placed[offset]
        }
        return result
    }

    /// The arrangement `shown` once the widget at `index` covers `cells`, the cells the user moves
    /// or resizes it to: the placement rule applies again, with this widget placed before the
    /// other widgets that start on its row. The hidden widgets, nil in `shown`, stay nil.
    public static func layout(_ shown: [DashboardCells?], placing index: Int, at cells: DashboardCells) -> [DashboardCells?] {
        guard shown.indices.contains(index), shown[index] != nil else { return shown }
        let indices = shown.indices.filter { shown[$0] != nil }
        var input = indices.compactMap { shown[$0] }
        guard let position = indices.firstIndex(of: index) else { return shown }
        input[position] = cells
        let placed = Self.placed(input, first: position)
        var result = shown
        for (offset, shownIndex) in indices.enumerated() {
            result[shownIndex] = placed[offset]
        }
        return result
    }
}

/// What a widget shows (docs/ui/dashboard.md › Widgets). Recent Chats and Cost were about Claude's
/// chats: Hephaestus V3 keeps them in the project file and never shows them, and lists the project's builds
/// instead.
nonisolated public enum DashboardWidgetKind: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case project
    case tickets
    case recentBuilds
    /// Kept in the list and never shown.
    case recentChats
    /// Kept in the list and never shown.
    case cost
    /// The pods of the project's service in the Dashboard's environment (docs/ui/dashboard.md ›
    /// Instances widget).
    case instances
    /// The service widgets: the map of the Service Map, the busiest arrows,
    /// the failed requests and the requests per minute of the Dashboard's time window.
    case serviceGraph
    case busiestCalls
    case failedRequests
    case requestsPerMinute

    public var id: Self { self }

    /// Whether the kind reads the Service Map, and so is hidden for a project whose map cannot be
    /// read.
    public var isGraph: Bool {
        switch self {
        case .serviceGraph, .busiestCalls, .failedRequests, .requestsPerMinute: true
        case .project, .tickets, .recentBuilds, .recentChats, .cost, .instances: false
        }
    }

    /// Whether the Dashboard shows widgets of the kind for `project` when the app offers `tools`: the tool
    /// whose data it shows is offered, and a service widget needs a project whose Service Map can be read.
    /// Recent Chats and Cost never show. A widget that doesn't show takes no place and keeps its stored
    /// position (docs/ui/dashboard.md › Placement).
    public func isShown(for project: Project, tools: Set<ToolKind>) -> Bool {
        switch self {
        case .project: true
        case .tickets: tools.contains(.tickets)
        case .recentBuilds: tools.contains(.builds)
        case .instances: tools.contains(.serviceMap)
        case .serviceGraph, .busiestCalls, .failedRequests, .requestsPerMinute: tools.contains(.serviceMap) && Self.hasServiceMap(project)
        case .recentChats, .cost: false
        }
    }

    /// The kinds the Dashboard shows for `project` when the app offers `tools`.
    public static func shown(for project: Project, tools: Set<ToolKind>) -> Set<DashboardWidgetKind> {
        Set(allCases.filter { $0.isShown(for: project, tools: tools) })
    }

    /// Whether the content fills the widget, whatever its size, instead of keeping the height it
    /// needs: the map and the chart (docs/ui/dashboard.md › Content).
    public var fillsWidget: Bool {
        self == .serviceGraph || self == .requestsPerMinute
    }

    /// Whether the widget has a `Number` setting.
    public var hasCount: Bool {
        self == .recentBuilds || self == .busiestCalls || self == .failedRequests
    }

    /// Whether the Service Map can be read for `project`: it is a service that runs somewhere.
    public static func hasServiceMap(_ project: Project) -> Bool {
        project.tools.contains(.serviceMap) && !project.environments.isEmpty
    }

    /// The kinds the Add Widget menu lists for `project` when the app offers `tools`, in this order: the kinds
    /// the Dashboard shows, Instances only for a service (docs/ui/dashboard.md › Edit mode).
    public static func addable(for project: Project, tools: Set<ToolKind>) -> [DashboardWidgetKind] {
        allCases.filter { kind in
            kind.isShown(for: project, tools: tools) && (kind != .instances || project.kind == .service)
        }
    }
}

/// A field of a Project widget.
nonisolated public enum DashboardProjectField: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case name
    case identifier
    case type
    case folder

    public var id: Self { self }
}

/// What a widget's content reads besides its settings: the project, and the environment and the
/// time window the Dashboard shows.
public struct DashboardContext {
    public let project: Project
    public let environment: DeploymentEnvironment?
    public let window: TimeWindow
    /// In edit mode a widget's content takes no click: a drag starts anywhere on the widget.
    public let editing: Bool

    public init(project: Project, environment: DeploymentEnvironment?, window: TimeWindow, editing: Bool) {
        self.project = project
        self.environment = environment
        self.window = window
        self.editing = editing
    }
}
