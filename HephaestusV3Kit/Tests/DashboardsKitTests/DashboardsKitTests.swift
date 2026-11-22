import AppKit
import AZDesign
import CoreGraphics
import Foundation
import Observation
import SwiftUI
import Testing
import ToolsFoundation
@testable import DashboardsKit

/// What the mock keeps of a project's Dashboard.
nonisolated struct DashboardLayout: Equatable {
    var widgets: [DashboardWidget]?
    var window: TimeWindow?
    var environment: String?
}

/// A store that keeps the layouts in memory and records each write. A project with nothing kept shows its
/// sample layout, as in the previews.
@Observable
final class MockDashboardLayoutStore: DashboardStore {
    var layouts: [Project.ID: DashboardLayout]
    private(set) var writes: [Project.ID] = []

    init(_ layouts: [Project.ID: DashboardLayout] = [:]) {
        self.layouts = layouts
    }

    func widgets(of project: Project.ID) -> [DashboardWidget]? {
        layouts[project]?.widgets ?? DashboardWidget.sample(for: project)
    }

    func window(of project: Project.ID) -> TimeWindow? {
        layouts[project]?.window
    }

    func environment(of project: Project.ID) -> String? {
        layouts[project]?.environment
    }

    func failure(of project: Project.ID) -> String? {
        nil
    }

    func setWidgets(_ widgets: [DashboardWidget], of project: Project.ID) {
        layouts[project, default: DashboardLayout()].widgets = widgets
        writes.append(project)
    }

    func setWindow(_ window: TimeWindow, of project: Project.ID) {
        layouts[project, default: DashboardLayout()].window = window
        writes.append(project)
    }

    func setEnvironment(_ name: String, of project: Project.ID) {
        layouts[project, default: DashboardLayout()].environment = name
        writes.append(project)
    }
}

private let orders = Project.sample("ORD")!
private let gateway = Project.sample("GW")!
private let tools = Project.sample("TLS")!

private func widget(_ number: Int, _ kind: DashboardWidgetKind, _ column: Int, _ row: Int, _ width: Int, _ height: Int) -> DashboardWidget {
    DashboardWidget(id: UUID(uuidString: String(format: "A0000000-0000-0000-0000-%012d", number))!, kind: kind,
                    column: column, row: row, width: width, height: height)
}

/// A, B side by side on row 0, C under both: the arrangement the step tests start from.
///
///     A A A A A A B B B B B B
///     C C C C C C C C C C C C
private let arranged = [
    widget(1, .project, 0, 0, 6, 4),
    widget(2, .tickets, 6, 0, 6, 4),
    widget(3, .recentBuilds, 0, 4, 12, 4),
]

/// A model in edit mode of `widgets` saved for Orders, with cells 40 points wide.
private func editingModel(_ widgets: [DashboardWidget] = arranged, project: Project = orders) -> (DashboardModel, MockDashboardLayoutStore) {
    let store = MockDashboardLayoutStore([project.id: DashboardLayout(widgets: widgets)])
    let model = DashboardModel(project: project, store: store, editing: true)
    model.areaWidth = 24 * 40 + 23 * DashboardGridMetrics.gap
    return (model, store)
}

private func slot(_ number: Int, in model: DashboardModel) -> DashboardSlot {
    DashboardSlot.slots(of: model.widgets).first { $0.id == widget(number, .project, 0, 0, 1, 1).id }!
}

private func cells(_ number: Int, in model: DashboardModel) -> DashboardCells? {
    model.widgets.first { $0.id == widget(number, .project, 0, 0, 1, 1).id }?.cells
}

/// Whether no two stored widgets cover the same cell.
private func noOverlap(_ widgets: [DashboardWidget]) -> Bool {
    let all = widgets.compactMap(\.cells)
    return all.indices.allSatisfy { a in all.indices.allSatisfy { b in a == b || !all[a].overlaps(all[b]) } }
}

@Suite("What the Dashboard shows")
struct DashboardContentTests {
    @Test("A tab's Dashboard takes the project as loaded now, not the one its kept model started with")
    @MainActor func projectAsLoaded() async throws {
        let model = DashboardModel(project: orders, store: SampleDashboardStore())
        let payments = try #require(Project.sample("PAY"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: DashboardRootView(model: model, project: payments) { _, _ in EmptyView() })
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.project.id == "PAY")
        window.contentView = nil
        window.close()
    }

    @Test("In the previews, a sample project with nothing saved shows its sample layout")
    func sampleLayout() {
        let model = DashboardModel(project: orders, store: SampleDashboardStore())
        #expect(model.widgets == DashboardWidget.sample(for: "ORD"))
        #expect(model.widgets.count == 8)
    }

    @Test("A project without a sample layout shows the default list")
    func defaultList() {
        let model = DashboardModel(project: tools, store: MockDashboardLayoutStore())
        #expect(model.widgets.map(\.kind) == [.project, .tickets, .recentBuilds])
        #expect(model.widgets.allSatisfy { $0.cells == nil })
    }

    @Test("A saved list replaces the sample, even an empty one")
    func savedList() {
        let model = DashboardModel(project: orders, store: MockDashboardLayoutStore(["ORD": DashboardLayout(widgets: [])]))
        #expect(model.widgets.isEmpty)
        #expect(model.showsNoWidgets)
    }

    @Test("Service widgets of a project whose map can't be read are hidden, and only they leave the Dashboard empty")
    func hiddenServiceWidgets() {
        let store = MockDashboardLayoutStore(["TLS": DashboardLayout(widgets: [widget(1, .serviceGraph, 0, 0, 12, 4)])])
        let model = DashboardModel(project: tools, store: store)
        #expect(model.showsNoWidgets)
        #expect(model.listOrder.isEmpty)
        #expect(!model.showsTimeWindow)
        #expect(!model.addableKinds.contains(.serviceGraph))
    }

    @Test("The toolbar's environment and time window follow the widgets shown")
    func toolbarItems() {
        #expect(DashboardModel(project: orders, store: MockDashboardLayoutStore()).showsTimeWindow)
        #expect(DashboardModel(project: orders, store: MockDashboardLayoutStore()).showsEnvironment)
        let instancesOnly = MockDashboardLayoutStore(["ORD": DashboardLayout(widgets: [widget(1, .instances, 0, 0, 12, 4)])])
        let model = DashboardModel(project: orders, store: instancesOnly)
        #expect(model.showsEnvironment)
        #expect(!model.showsTimeWindow)
        #expect(!DashboardModel(project: tools, store: MockDashboardLayoutStore()).showsEnvironment)
    }

    @Test("The environment is the one chosen last, else the first not healthy, else the first")
    func environment() {
        let store = MockDashboardLayoutStore()
        let model = DashboardModel(project: orders, store: store)
        #expect(model.environment?.name == "Staging")
        // Edge Gateway takes Shop's settings, so it reads Shop's environments, whose Staging is degraded.
        #expect(DashboardModel(project: gateway, store: store).environment?.name == "Staging")
        model.setEnvironment("Production")
        #expect(model.environment?.name == "Production")
        #expect(store.layouts["ORD"]?.environment == "Production")
        #expect(store.layouts["ORD"]?.widgets == nil, "Choosing an environment saves no widget list")
    }

    @Test("An environment the project doesn't have is not saved")
    func unknownEnvironment() {
        let store = MockDashboardLayoutStore()
        DashboardModel(project: orders, store: store).setEnvironment("Nowhere")
        #expect(store.writes.isEmpty)
    }

    @Test("The time window is the last hour until another is chosen")
    func timeWindow() {
        let store = MockDashboardLayoutStore()
        let model = DashboardModel(project: orders, store: store)
        #expect(model.window == .hour)
        model.setWindow(.day)
        #expect(model.window == .day)
        #expect(model.context.window == .day)
        #expect(store.layouts["ORD"]?.window == .day)
    }

    @Test("A change shows in every window of the project")
    func sharedStore() {
        let store = MockDashboardLayoutStore()
        let first = DashboardModel(project: orders, store: store)
        let second = DashboardModel(project: orders, store: store)
        first.setWindow(.fiveMinutes)
        #expect(second.window == .fiveMinutes)
    }

    @Test("The list is in the grid's order: by row, then by column")
    func listOrder() {
        let widgets = [
            widget(1, .recentBuilds, 0, 4, 12, 4),
            widget(2, .tickets, 12, 0, 12, 4),
            widget(3, .project, 0, 0, 12, 4),
        ]
        let model = DashboardModel(project: orders, store: MockDashboardLayoutStore(["ORD": DashboardLayout(widgets: widgets)]))
        #expect(model.listOrder == [2, 1, 0])
    }

    @Test("A widget's title is its Title setting, or its kind's")
    func title() {
        var tickets = DashboardWidget(kind: .tickets)
        #expect(DashboardContent.title(of: tickets) == DashboardWidgetKind.tickets.title)
        tickets.title = "  Open work  "
        #expect(DashboardContent.title(of: tickets) == "Open work")
    }
}

@Suite("Edit mode")
struct DashboardEditModeTests {
    @Test("Add Widget measures the new widget with the window's stores, not samples")
    @MainActor
    func addWidgetMeasuresInWindowEnvironment() {
        var environment = EnvironmentValues()
        environment[MeasuredRowsKey.self] = 12
        let widget = DashboardWidget(kind: .recentBuilds)
        let withRows = DashboardWidgetCard<MeasuredRows>.neededHeight(
            of: widget, width: 400, content: MeasuredRows(), environment: environment
        )
        let empty = DashboardWidgetCard<MeasuredRows>.neededHeight(
            of: widget, width: 400, content: MeasuredRows(), environment: EnvironmentValues()
        )
        #expect(withRows > empty + 100)
    }

    @Test("Done closes the settings popover and ends a drag")
    func endEditing() {
        let (model, _) = editingModel()
        let a = slot(1, in: model)
        model.settingsSlot = a
        model.dragChanged(a, .move, start: .zero, location: CGPoint(x: 10, y: 0), scrollOffset: 0)
        #expect(model.drag != nil)
        model.endEditing()
        #expect(!model.editing)
        #expect(model.settingsSlot == nil)
        #expect(model.drag == nil)
    }

    @Test("Out of edit mode nothing moves")
    func notEditing() {
        let (model, store) = editingModel()
        model.endEditing()
        let a = slot(1, in: model)
        #expect(!model.canStep(a, .moveRight))
        model.step(a, .moveRight)
        model.dragChanged(a, .move, start: .zero, location: CGPoint(x: 200, y: 0), scrollOffset: 0)
        #expect(model.drag == nil)
        #expect(store.writes.isEmpty)
    }

    @Test("Remove takes the widget out, and those under it rise")
    func remove() {
        let (model, _) = editingModel()
        model.remove(slot(1, in: model))
        #expect(model.widgets.count == 2)
        #expect(cells(3, in: model)?.row == 4, "C stays under B, which keeps its place")
        model.remove(slot(2, in: model))
        #expect(cells(3, in: model)?.row == 0)
    }

    @Test("A widget that leaves the list closes its settings and ends its drag")
    func keep() {
        let (model, _) = editingModel()
        let a = slot(1, in: model)
        model.settingsSlot = a
        model.dragChanged(a, .move, start: .zero, location: CGPoint(x: 10, y: 0), scrollOffset: 0)
        model.keep([slot(2, in: model), slot(3, in: model)])
        #expect(model.settingsSlot == nil)
        #expect(model.drag == nil)
    }

    @Test("Add Widget appends at column 0, half the grid wide, and it rises")
    func add() {
        let (model, _) = editingModel([widget(1, .project, 0, 0, 6, 4), widget(2, .tickets, 12, 0, 12, 6)])
        model.add(.recentBuilds, rows: 3)
        let added = model.widgets.last
        #expect(added?.kind == .recentBuilds)
        #expect(added?.cells == DashboardCells(column: 0, row: 4, width: 12, height: 3))
    }

    @Test("The first change of a project with nothing saved saves its list with positions")
    func firstChange() {
        let store = MockDashboardLayoutStore()
        let model = DashboardModel(project: tools, store: store, editing: true)
        model.areaWidth = 1000
        model.update(DashboardSlot.slots(of: model.widgets)[0]) { $0.title = "Mine" }
        #expect(store.layouts["TLS"]?.widgets?.first?.title == "Mine")
        #expect(store.layouts["TLS"]?.widgets?.count == 3)
    }

    @Test("A drag released on other cells places the widget there; released in place it changes nothing")
    func drag() {
        let (model, store) = editingModel()
        let a = slot(1, in: model)
        let pitch = model.metrics.pitch
        model.dragChanged(a, .move, start: CGPoint(x: 10, y: 10), location: CGPoint(x: 11, y: 10), scrollOffset: 0)
        model.dragEnded(a, .move, location: CGPoint(x: 12, y: 10))
        #expect(store.writes.isEmpty)
        model.dragChanged(a, .move, start: CGPoint(x: 10, y: 10), location: CGPoint(x: 10 + pitch, y: 10), scrollOffset: 0)
        #expect(model.grid(metrics: model.metrics).placeholder?.column == 1)
        model.dragEnded(a, .move, location: CGPoint(x: 10 + 18 * pitch, y: 10))
        #expect(cells(1, in: model)?.column == 18)
        #expect(noOverlap(model.widgets))
    }

    @Test("Each widget, and each of its controls, has its own identifier")
    func identifiers() {
        let twin = DashboardWidget(id: arranged[0].id, kind: .project)
        let slots = DashboardSlot.slots(of: arranged + [twin])
        #expect(Set(slots.map(\.identifier)).count == 4)
        #expect(slots[0].identifier == arranged[0].id.uuidString)
        #expect(slots[3].identifier == "\(arranged[0].id.uuidString)-2")
    }
}

@Suite("Steps of the keyboard and VoiceOver")
struct DashboardStepTests {
    @Test("Left stops at column 0 and right at column 24")
    func horizontal() {
        let (model, _) = editingModel()
        #expect(!model.canStep(slot(1, in: model), .moveLeft))
        #expect(!model.canStep(slot(3, in: model), .moveLeft))
        #expect(model.canStep(slot(2, in: model), .moveRight))
        model.step(slot(2, in: model), .moveRight)
        #expect(cells(2, in: model)?.column == 7)
        let (edge, _) = editingModel([widget(1, .project, 18, 0, 6, 4)])
        #expect(!edge.canStep(slot(1, in: edge), .moveRight))
    }

    @Test("Up puts the widget before the one above it")
    func up() {
        let (model, _) = editingModel()
        #expect(!model.canStep(slot(1, in: model), .moveUp))
        model.step(slot(3, in: model), .moveUp)
        #expect(cells(3, in: model)?.row == 0)
        #expect(cells(1, in: model)?.row == 4)
        #expect(cells(2, in: model)?.row == 4)
        #expect(noOverlap(model.widgets))
    }

    @Test("Down puts the widget after the one under it, and does nothing without one")
    func down() {
        let (model, _) = editingModel()
        #expect(!model.canStep(slot(3, in: model), .moveDown))
        model.step(slot(1, in: model), .moveDown)
        #expect(cells(1, in: model)!.row >= 8)
        #expect(cells(3, in: model)?.row == 4)
        #expect(noOverlap(model.widgets))
    }

    @Test("Down then up brings a widget back over the one it passed")
    func downThenUp() {
        let (model, _) = editingModel([widget(1, .project, 0, 0, 12, 4), widget(2, .tickets, 0, 4, 12, 4)])
        model.step(slot(1, in: model), .moveDown)
        #expect(cells(1, in: model)?.row == 4)
        #expect(cells(2, in: model)?.row == 0)
        model.step(slot(1, in: model), .moveUp)
        #expect(cells(1, in: model)?.row == 0)
        #expect(cells(2, in: model)?.row == 4)
    }

    @Test("Wider and taller add a cell; the neighbor makes room")
    func larger() {
        let (model, _) = editingModel()
        model.step(slot(1, in: model), .wider)
        #expect(cells(1, in: model)?.width == 7)
        model.step(slot(1, in: model), .taller)
        #expect(cells(1, in: model)?.height == 5)
        #expect(noOverlap(model.widgets))
    }

    @Test("Wider stops at column 24")
    func widest() {
        let (model, _) = editingModel([widget(1, .project, 12, 0, 12, 4)])
        #expect(!model.canStep(slot(1, in: model), .wider))
        #expect(model.canStep(slot(1, in: model), .narrower))
    }

    @Test("Narrower and shorter stop at the smallest size, the title row's")
    func smallest() {
        let (model, _) = editingModel()
        let a = slot(1, in: model)
        // A title row that needs 6 cells across and 4 down at 40-point cells.
        model.measuredSmallest(a, size: CGSize(width: model.metrics.length(6), height: model.metrics.length(4)))
        #expect(!model.canStep(a, .narrower))
        #expect(!model.canStep(a, .shorter))
        model.measuredSmallest(a, size: CGSize(width: 30, height: 30))
        model.step(a, .narrower)
        model.step(a, .shorter)
        #expect(cells(1, in: model) == DashboardCells(column: 0, row: 0, width: 5, height: 3))
    }

    @Test("A widget smaller than its title row grows to it at once")
    func growsToSmallest() {
        let resized = DashboardEdits.resized(DashboardCells(column: 0, row: 0, width: 2, height: 1), .wider,
                                             smallest: DashboardSmallestSize(columns: 5, rows: 2))
        #expect(resized?.width == 5)
        #expect(DashboardEdits.resized(DashboardCells(column: 0, row: 0, width: 2, height: 1), .narrower,
                                       smallest: DashboardSmallestSize(columns: 5, rows: 2)) == nil)
    }

    @Test("No step while a drag is in progress")
    func duringDrag() {
        let (model, _) = editingModel()
        let a = slot(1, in: model)
        model.dragChanged(a, .move, start: .zero, location: CGPoint(x: 10, y: 0), scrollOffset: 0)
        #expect(model.steps(of: slot(2, in: model)).isEmpty)
    }

    @Test("The steps offered are those that change something")
    func offered() {
        let (model, _) = editingModel()
        #expect(model.steps(of: slot(1, in: model)) == [.moveRight, .moveDown, .wider, .narrower, .taller, .shorter])
    }
}

@Suite("Settings")
struct DashboardSettingsTests {
    @Test("A title is trimmed, one line of at most 100 characters")
    func titleValidation() {
        #expect(DashboardContent.title(from: "  Orders  ") == "Orders")
        #expect(DashboardContent.title(from: String(repeating: "a", count: 100)) != nil)
        #expect(DashboardContent.title(from: String(repeating: "a", count: 101)) == nil)
        #expect(DashboardContent.title(from: "Two\nlines") == nil)
        #expect(DashboardContent.title(from: "") == "")
    }

    @Test("The last checked box stays checked, and boxes keep the settings' order")
    func checkboxes() {
        #expect(DashboardEdits.flipping(TicketStatus.done, in: [.done]) == [.done])
        #expect(DashboardEdits.flipping(TicketStatus.draft, in: [.done, .created]) == [.draft, .created, .done])
        // AZDesign's CheckboxGroup locks the last checked box (keepsOneChecked).
        #expect(CheckboxGroup<DashboardProjectField>.isLastChecked(.name, of: DashboardProjectField.allCases, isChecked: { $0 == .name }))
    }

    @Test("Number steps within 1–20 from the newest value")
    func count() {
        var widget = DashboardWidget(kind: .recentBuilds, count: 20)
        #expect(DashboardEdits.steppingCount(of: widget, by: 1) == 20)
        widget.count = 0
        #expect(DashboardEdits.steppingCount(of: widget, by: -1) == 1)
        #expect(DashboardEdits.steppingCount(of: widget, by: 1) == 2)
    }

    @Test("A change of settings stores no position")
    func settingsKeepPositions() {
        let store = MockDashboardLayoutStore()
        let model = DashboardModel(project: tools, store: store, editing: true)
        let first = DashboardSlot.slots(of: model.widgets)[0]
        model.update(first) { $0.count = 9 }
        #expect(store.layouts["TLS"]?.widgets?.allSatisfy { $0.cells == nil } == true)
    }
}

/// How many rows `MeasuredRows` shows: the stand-in for a store the window's environment holds.
private struct MeasuredRowsKey: EnvironmentKey {
    static let defaultValue = 0
}

/// A widget's content whose height depends on its environment, as Recent Builds does on the build store.
private struct MeasuredRows: View {
    @Environment(\.self) private var environment

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<environment[MeasuredRowsKey.self], id: \.self) { _ in
                Text(verbatim: "Run").frame(height: 20)
            }
        }
    }
}
