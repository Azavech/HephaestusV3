import CoreGraphics
import Foundation
import Observation
import ToolsFoundation

/// A Dashboard window: the project's widgets, the environment and the time window it shows, edit mode
/// with the widget being dragged and the one whose settings are open, and every change the user makes,
/// saved at once in a `DashboardLayoutStore` (docs/ui/dashboard.md).
///
/// The view reports what only its layout knows: the width of the widget area, the height each widget
/// needs, and the size of each title row, which the arrangement and the smallest size depend on.
@Observable
final class DashboardModel {
    let project: Project
    private let store: any DashboardLayoutStore

    /// Whether the widgets can be added, removed, moved, resized and set up. Edit mode belongs to the
    /// window: it ends with `Done`, in the list, and when the window switches project or closes.
    private(set) var editing: Bool
    /// The widget whose settings popover is open.
    var settingsSlot: DashboardSlot?
    /// The move or the resize in progress.
    private(set) var drag: DashboardDrag?

    /// The width of the widget area, which gives the size of the cells, for what happens after the
    /// layout: a drag, an added widget, a removed one, a step. 0 until the area is laid out.
    var areaWidth: CGFloat = 0
    /// The height each widget needs at its width for its title row, its content and its padding: the
    /// rows of a widget without position (docs/ui/dashboard.md › Lists without positions).
    private(set) var neededHeights: [DashboardSlot: CGFloat] = [:]
    /// The size of each widget's title row at full width, with its padding: the smallest size of the
    /// widget, known in edit mode (docs/ui/dashboard.md › Edit mode).
    private(set) var smallestSizes: [DashboardSlot: CGSize] = [:]

    init(project: Project, store: any DashboardLayoutStore, editing: Bool = false) {
        self.project = project
        self.store = store
        self.editing = editing
    }

    // MARK: What it shows

    /// The stored list, the project's sample layout, or the default list (docs/ui/dashboard.md ›
    /// Default list and sample layouts).
    var widgets: [DashboardWidget] {
        store.layout(of: project.id)?.widgets ?? DashboardWidget.sample(for: project.id) ?? DashboardWidget.defaultList(for: project)
    }

    /// The widget of a slot, nil once it left the list.
    func widget(_ slot: DashboardSlot) -> DashboardWidget? {
        let list = widgets
        return slot.index(in: list).map { list[$0] }
    }

    /// Whether the project's Service Map can be read: its service widgets show and are offered.
    var graphEnabled: Bool {
        DashboardWidgetKind.hasServiceMap(project)
    }

    /// Whether the Dashboard shows a service widget: the time window shows in the toolbar.
    var showsTimeWindow: Bool {
        graphEnabled && widgets.contains { $0.kind.isGraph }
    }

    /// Whether a shown widget reads the environment: the environment shows in the toolbar.
    var showsEnvironment: Bool {
        !project.deploymentEnvironments.isEmpty && (showsTimeWindow || widgets.contains { $0.kind == .instances })
    }

    /// Whether no widget shows: the list is empty, or holds only service widgets that are hidden.
    var showsNoWidgets: Bool {
        !widgets.contains { graphEnabled || !$0.kind.isGraph }
    }

    /// The kinds the Add Widget menu offers.
    var addableKinds: [DashboardWidgetKind] {
        DashboardWidgetKind.addable(for: project)
    }

    /// The environment the Instances and service widgets read: the one chosen last, or, as the Service
    /// Map opens, the first that is not healthy, or the first.
    var environment: DeploymentEnvironment? {
        if let name = store.layout(of: project.id)?.environment,
           let chosen = project.deploymentEnvironments.first(where: { $0.name == name }) {
            return chosen
        }
        return project.deploymentEnvironments.first { $0.health != .healthy } ?? project.deploymentEnvironments.first
    }

    /// The time window of the service widgets, the last hour by default as in V2.
    var window: TimeWindow {
        store.layout(of: project.id)?.window ?? .hour
    }

    func setEnvironment(_ name: String) {
        guard project.deploymentEnvironments.contains(where: { $0.name == name }) else { return }
        save { $0.environment = name }
    }

    func setWindow(_ window: TimeWindow) {
        save { $0.window = window }
    }

    /// What each widget's content reads besides its settings.
    var context: DashboardContext {
        DashboardContext(project: project, environment: environment, window: window, editing: editing)
    }

    // MARK: Arrangement

    var metrics: DashboardGridMetrics {
        DashboardGridMetrics(width: areaWidth)
    }

    /// What the arrangement depends on now: the rows each widget needs at the cell size `metrics`
    /// gives.
    func arrangement(_ metrics: DashboardGridMetrics) -> DashboardArrangement {
        DashboardArrangement(graphEnabled: graphEnabled, rows: neededHeights.mapValues { metrics.cells(holding: $0) })
    }

    /// The cells a widget shows at the window's cell size; nil for a hidden service widget.
    func cells(of slot: DashboardSlot) -> DashboardCells? {
        let list = widgets
        guard let index = slot.index(in: list) else { return nil }
        return arrangement(metrics).cells(of: list)[index]
    }

    /// The one-per-row list: the indexes of the shown widgets in the grid's order, by row, then by
    /// column (docs/ui/dashboard.md › One widget per row).
    var listOrder: [Int] {
        let cells = DashboardArrangement(graphEnabled: graphEnabled).cells(of: widgets)
        let shown: [Int] = cells.indices.filter { cells[$0] != nil }
        return shown.sorted { a, b in
            let (first, second) = (cells[a]!, cells[b]!)
            return first.row != second.row ? first.row < second.row : first.column < second.column
        }
    }

    /// What the grid shows at `metrics`: each shown widget on its cells, and during a drag, the widget
    /// that follows the pointer and the placeholder of the cells where it will land, with the other
    /// widgets making room.
    func grid(metrics: DashboardGridMetrics) -> DashboardGridState {
        let list = widgets
        let slots = DashboardSlot.slots(of: list)
        let live = drag.flatMap { live($0, in: list, metrics: metrics) }
        let cells = live?.cells ?? arrangement(metrics).cells(of: list)
        let items = list.indices.compactMap { index in
            cells[index].map { cells in
                DashboardItem(slot: slots[index], widget: list[index], cells: cells,
                              // A widget without position shows once the rows it needs are known.
                              isMeasured: list[index].cells != nil || neededHeights[slots[index]] != nil)
            }
        }
        return DashboardGridState(
            items: items,
            floating: live.map { (slots[$0.index], $0.frame) },
            placeholder: live.flatMap { $0.cells[$0.index] }
        )
    }

    /// The arrangement while a widget is moved or resized: the frame at which it follows the pointer,
    /// the cells it asks for, and the cells of every widget once the others have made room. Nil when
    /// the widget is no longer shown.
    private func live(_ drag: DashboardDrag, in list: [DashboardWidget], metrics: DashboardGridMetrics) -> DashboardLive? {
        let shown = drag.arrangement.cells(of: list)
        guard let index = drag.slot.index(in: list), let start = shown[index] else { return nil }
        let target = drag.target(from: start, metrics: metrics, smallest: smallestSize(of: drag.slot, metrics: metrics))
        return DashboardLive(index: index, frame: target.frame, target: target.cells, shown: shown,
                             cells: DashboardGrid.layout(shown, placing: index, at: target.cells))
    }

    /// The smallest size of a widget at the cell size `metrics` gives: its title row at full width
    /// with both buttons, or one cell until that is measured.
    private func smallestSize(of slot: DashboardSlot, metrics: DashboardGridMetrics) -> DashboardSmallestSize {
        smallestSizes[slot].map(metrics.smallestSize(titleRow:)) ?? DashboardSmallestSize()
    }

    // MARK: Edit mode

    func startEditing() {
        editing = true
    }

    /// Ends edit mode: the settings popover closes and a drag in progress ends.
    func endEditing() {
        editing = false
        settingsSlot = nil
        drag = nil
    }

    /// `Add Widget`: the widget, appended with default settings, gets `rows`, the rows its content
    /// needs at the cell size of the window.
    func add(_ kind: DashboardWidgetKind, rows: Int) {
        let arrangement = arrangement(metrics)
        change { DashboardEdits.appending(kind, rows: rows, to: $0, arrangement: arrangement) }
    }

    /// The remove button: the other widgets keep their places, and those under it rise.
    func remove(_ slot: DashboardSlot) {
        let arrangement = arrangement(metrics)
        change { DashboardEdits.removing(slot, from: $0, arrangement: arrangement) }
    }

    /// A change of a widget's settings, applied to the newest list.
    func update(_ slot: DashboardSlot, _ update: (inout DashboardWidget) -> Void) {
        change { DashboardEdits.updating(slot, in: $0, update) }
    }

    /// Whether a step of the keyboard or VoiceOver changes anything for the widget.
    func canStep(_ slot: DashboardSlot, _ step: DashboardStep) -> Bool {
        guard editing, drag == nil else { return false }
        let metrics = metrics
        return DashboardEdits.target(of: slot, step, in: widgets, arrangement: arrangement(metrics),
                                     smallest: smallestSize(of: slot, metrics: metrics)) != nil
    }

    /// The steps that change anything for the widget, in the order of `DashboardStep`.
    func steps(of slot: DashboardSlot) -> [DashboardStep] {
        DashboardStep.allCases.filter { canStep(slot, $0) }
    }

    /// Moves the widget one cell, or makes it one cell larger or smaller, as a drag would.
    func step(_ slot: DashboardSlot, _ step: DashboardStep) {
        guard editing, drag == nil else { return }
        let metrics = metrics
        let arrangement = arrangement(metrics)
        let smallest = smallestSize(of: slot, metrics: metrics)
        change { DashboardEdits.stepping(slot, step, in: $0, arrangement: arrangement, smallest: smallest) }
    }

    // MARK: Drag

    /// A drag that moves a widget, or resizes it by its handle, starts or goes on. `scrollOffset` is
    /// how far the widget area is scrolled.
    func dragChanged(_ slot: DashboardSlot, _ kind: DashboardDrag.Kind, start: CGPoint, location: CGPoint, scrollOffset: CGFloat) {
        guard editing else { return }
        if drag?.slot == slot, drag?.kind == kind {
            drag?.location = location
        } else {
            drag = DashboardDrag(slot: slot, kind: kind, start: start, location: location,
                                 startOffset: scrollOffset, offset: scrollOffset, arrangement: arrangement(metrics))
        }
    }

    /// The drag ends: releasing the widget applies the arrangement; nothing changes when no widget
    /// changed place or size.
    func dragEnded(_ slot: DashboardSlot, _ kind: DashboardDrag.Kind, location: CGPoint) {
        guard var ended = drag, ended.slot == slot, ended.kind == kind else { return }
        ended.location = location
        drag = nil
        guard let live = live(ended, in: widgets, metrics: metrics), live.cells != live.shown else { return }
        let target = live.target
        let arrangement = ended.arrangement
        change { DashboardEdits.placing(slot, at: target, in: $0, arrangement: arrangement) }
    }

    /// The widget area scrolled: the dragged widget stays under the pointer.
    func scrolled(to offset: CGFloat) {
        if let drag, drag.offset != offset {
            self.drag?.offset = offset
        }
    }

    // MARK: Measures

    /// Also during a drag, which keeps the rows it started with: a height that changed meanwhile
    /// counts once the widget is released.
    func measured(_ slot: DashboardSlot, height: CGFloat) {
        if neededHeights[slot] != height {
            neededHeights[slot] = height
        }
    }

    func measuredSmallest(_ slot: DashboardSlot, size: CGSize) {
        if smallestSizes[slot] != size {
            smallestSizes[slot] = size
        }
    }

    /// The list changed: what is known of the widgets that left it is forgotten, and a drag of one of
    /// them ends, as its settings popover closes.
    func keep(_ slots: [DashboardSlot]) {
        let kept = Set(slots)
        neededHeights = neededHeights.filter { kept.contains($0.key) }
        smallestSizes = smallestSizes.filter { kept.contains($0.key) }
        if let drag, !kept.contains(drag.slot) {
            self.drag = nil
        }
        if let settingsSlot, !kept.contains(settingsSlot) {
            self.settingsSlot = nil
        }
    }

    // MARK: Saving

    /// Applies a change to the newest list; the first change of a project with nothing saved saves its
    /// list with that change.
    private func change(_ edit: ([DashboardWidget]) -> [DashboardWidget]?) {
        let stored = widgets
        guard let list = edit(stored), list != stored else { return }
        save { $0.widgets = list }
    }

    private func save(_ change: (inout DashboardLayout) -> Void) {
        var layout = store.layout(of: project.id) ?? DashboardLayout()
        change(&layout)
        store.setLayout(layout, of: project.id)
    }
}

/// What the grid shows (`DashboardModel.grid(metrics:)`).
struct DashboardGridState {
    /// The shown widgets on their cells.
    var items: [DashboardItem]
    /// During a drag: the widget that follows the pointer, and its frame.
    var floating: (slot: DashboardSlot, frame: CGRect)?
    /// During a drag: the cells where the widget will land.
    var placeholder: DashboardCells?
}

/// A shown widget with its slot and the cells it covers.
struct DashboardItem {
    var slot: DashboardSlot
    var widget: DashboardWidget
    var cells: DashboardCells
    /// Whether the rows it covers are known: a widget without position stays invisible until then.
    var isMeasured: Bool
}

/// The arrangement while a widget is moved or resized.
private struct DashboardLive {
    /// The index of the widget in the list.
    var index: Int
    /// The frame at which the widget follows the pointer.
    var frame: CGRect
    /// The cells the widget asks for.
    var target: DashboardCells
    /// The cells of every widget when the drag started, and once the others have made room.
    var shown: [DashboardCells?]
    var cells: [DashboardCells?]
}
