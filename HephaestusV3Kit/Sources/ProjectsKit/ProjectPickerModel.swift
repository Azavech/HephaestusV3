import Foundation
import Observation
import ToolsFoundation

/// A list of projects to pick from with the keyboard: the project switcher's popover and the menu bar
/// panel. Typing filters it, one row is highlighted, ↑ ↓ move the highlight, and Return picks it.
///
/// The switcher lists every project but lets you pick only those with its window's tool.
@Observable
final class ProjectPickerModel {
    /// The projects as a tree, from the store.
    let tree: ProjectTree
    /// The tool a project needs to be picked; nil when every project can be.
    let requiredTool: ToolKind?
    /// The filter: a project's name or identifier. Each change highlights the first match.
    var query = "" {
        didSet {
            if query != oldValue {
                highlightFirst()
            }
        }
    }
    /// The row Return acts on: the first match, the arrow keys, or the pointer.
    private(set) var highlighted: Project.ID?

    /// A list without a filter, highlighting `id` when it can be picked, otherwise the first row that can.
    init(store: any ProjectStore, requiredTool: ToolKind? = nil, highlighting id: Project.ID? = nil) {
        self.tree = ProjectTree(store.projects)
        self.requiredTool = requiredTool
        reset(highlighting: id)
    }

    // MARK: Contents

    /// Whether the filter holds text: the list then shows the matches alone, flat.
    var isFiltering: Bool {
        !ProjectTree.normalized(query).isEmpty
    }

    /// The rows by kind: the tree, or the matches alone while filtering.
    var sections: [ProjectListSection] {
        tree.sections(matching: query)
    }

    /// The rows in list order.
    var entries: [ProjectListEntry] {
        sections.flatMap(\.entries)
    }

    /// Whether the filter matches no project.
    var hasNoMatches: Bool {
        isFiltering && entries.isEmpty
    }

    /// Whether `project` can be picked: it has the required tool.
    func isAvailable(_ project: Project) -> Bool {
        requiredTool.map(project.tools.contains) ?? true
    }

    /// The highlighted project, when it is listed and can be picked: what Return acts on.
    var highlightedProject: Project? {
        entries.first { $0.project.id == highlighted && isAvailable($0.project) }?.project
    }

    // MARK: Highlight

    /// Highlights a row, as the pointer does. A project that can't be picked isn't highlighted.
    func highlight(_ id: Project.ID) {
        guard let entry = entries.first(where: { $0.project.id == id }), isAvailable(entry.project) else { return }
        highlighted = id
    }

    /// Moves the highlight one row down (`1`) or up (`-1`), over the rows that can be picked, stopping
    /// at the first and last. With no highlight, down goes to the first row and up to the last.
    func move(by step: Int) {
        let ids = entries.filter { isAvailable($0.project) }.map(\.project.id)
        guard !ids.isEmpty else { return }
        let current = highlighted.flatMap { ids.firstIndex(of: $0) } ?? (step > 0 ? -1 : ids.count)
        highlighted = ids[min(max(current + step, 0), ids.count - 1)]
    }

    /// Starts afresh, as each opening does: no filter, and the highlight on `id` when it can be picked,
    /// otherwise on the first row that can.
    func reset(highlighting id: Project.ID? = nil) {
        query = ""
        highlightFirst()
        if let id {
            highlight(id)
        }
    }

    /// Highlights the first row that can be picked, or nothing when no row can.
    private func highlightFirst() {
        highlighted = entries.first { isAvailable($0.project) }?.project.id
    }
}
