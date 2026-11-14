import ExternalTools
import FileStorage
import Foundation
import ProjectData
import Testing
import ToolsFoundation
@testable import DashboardsKit

private struct NoProcesses: ProcessRunning {
    func run(_ request: ProcessRequest, input: Data?, timeout: Duration?) async throws -> ProcessResult {
        ProcessResult(termination: .exited(1))
    }
}

/// A temporary world: a data folder and one project `ORD` in `Repo`, whose project file starts with `extra`,
/// all deleted afterwards. Tests never touch the user's projects or data folder.
@MainActor
private final class DashboardWorld {
    let root: URL
    let projectFile: URL
    let session: ProjectSession
    let store: LiveDashboardStore

    init(extra: String = "") async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LiveDashboardStoreTests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        let repo = root.appendingPathComponent("Repo")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".hephaestus"), withIntermediateDirectories: true)
        projectFile = repo.appendingPathComponent(".hephaestus/project.yml")
        try Data(("schema: 1\nid: ORD\nname: Orders\ncreated: 2026-10-31T09:30:00Z\n" + extra).utf8).write(to: projectFile)
        let data = DataFolder(url: root.appendingPathComponent("Data"))
        try data.createIfNeeded()
        try YAMLFile.write(RegistryFile(projects: [repo.path]), to: data.registryFile)
        session = ProjectSession(dataFolder: data, runner: NoProcesses(), processEnvironment: [:])
        await session.start()
        store = LiveDashboardStore(session: session)
    }

    var text: String {
        get throws { try String(contentsOf: projectFile, encoding: .utf8) }
    }

    func close() async {
        await session.stop()
        try? FileManager.default.removeItem(at: root)
    }
}

/// A Recent Chats widget with its settings and an unknown key, then a Tickets widget.
private let v2Widgets = """
    dashboardWidgets:
    - id: 00000000-0000-0000-0000-000000000003
      kind: recentChats
      title: ''
      column: 0
      row: 0
      width: 12
      height: 4
      chatCount: 7
      chatKinds:
      - ticket
      - bundle
      mood: calm
    - id: 3E5A7B9D-2C4F-4E6A-8B9C-0D1E2F3A4B5C
      kind: tickets
      title: Work
      column: 12
      row: 0
      width: 12
      height: 4
      statuses:
      - todo
      - in_progress
      includeSubprojects: false
    dashboardGraphWindow: week

    """

@Suite("The Dashboard on the project files")
@MainActor
struct LiveDashboardStoreTests {
    @Test("A project without a stored list shows the default list, never a sample layout, whatever its identifier")
    func defaultList() async throws {
        let world = try await DashboardWorld()
        defer { Task { await world.close() } }
        let project = Project.sample("ORD")!
        let model = DashboardModel(project: project, store: world.store)
        #expect(world.store.widgets(of: "ORD") == nil)
        #expect(model.widgets == DashboardWidget.defaultList(for: project))
        #expect(world.store.window(of: "ORD") == nil)
    }

    @Test("Widgets are read with their settings; Recent Chats is kept and never shown; week shows the last hour")
    func reading() async throws {
        let world = try await DashboardWorld(extra: v2Widgets)
        defer { Task { await world.close() } }
        let widgets = try #require(world.store.widgets(of: "ORD"))
        #expect(widgets.map(\.kind) == [.recentChats, .tickets])
        #expect(widgets[1].title == "Work" && widgets[1].statuses == [.created, .inProgress] && !widgets[1].includeSubprojects)
        #expect(world.store.window(of: "ORD") == nil)
        let model = DashboardModel(project: Project.sample("ORD")!, store: world.store, tools: [.dashboard, .tickets])
        #expect(!model.shownKinds.contains(.recentChats))
        #expect(model.listOrder == [1])
    }

    @Test("A change is written in the file's layout, and what isn't shown survives it")
    func writing() async throws {
        let world = try await DashboardWorld(extra: v2Widgets)
        defer { Task { await world.close() } }
        let model = DashboardModel(project: Project.sample("ORD")!, store: world.store, tools: [.dashboard, .tickets], editing: true)
        model.areaWidth = 1000
        let tickets = DashboardSlot.slots(of: model.widgets)[1]
        model.update(tickets) { $0.title = "Tickets of the week" }
        #expect(model.widgets[1].title == "Tickets of the week", "The change shows before it is written")
        await world.store.settle()
        let text = try world.text
        #expect(text.contains("""
            - id: 00000000-0000-0000-0000-000000000003
              kind: recentChats
              title: ''
              column: 0
              row: 0
              width: 12
              height: 4
              chatCount: 7
              chatKinds:
              - ticket
              - bundle
              mood: calm
            - id: 3E5A7B9D-2C4F-4E6A-8B9C-0D1E2F3A4B5C
              kind: tickets
              title: Tickets of the week
              column: 12
              row: 0
              width: 12
              height: 4
              statuses:
              - todo
              - in_progress
              includeSubprojects: false
            dashboardGraphWindow: week
            """))
        #expect(world.store.widgets(of: "ORD")?[1].title == "Tickets of the week")
    }

    @Test("The first change of a project without a stored list stores the default list with it")
    func firstChange() async throws {
        let world = try await DashboardWorld()
        defer { Task { await world.close() } }
        let model = DashboardModel(project: Project.sample("ORD")!, store: world.store, editing: true)
        model.areaWidth = 1000
        let builds = try #require(DashboardSlot.slots(of: model.widgets).first { model.widget($0)?.kind == .recentBuilds })
        model.update(builds) { $0.count = 9 }
        await world.store.settle()
        let entries = try #require(world.session.snapshot.project("ORD")?.file.dashboardWidgets)
        #expect(entries.map(\.kind) == [.project, .tickets, .recentBuilds, .serviceGraph])
        #expect(entries.map(\.id) == (1...4).map(DashboardWidgetEntry.defaultID))
        #expect(entries[1].statuses == [.draft, .todo, .inProgress, .review, .done])
        #expect(entries[2].count == 9)
        #expect(entries.allSatisfy { $0.column == nil }, "A change of settings stores no position")
        #expect(try world.text.contains("  kind: recentBuilds\n  title: ''\n  count: 9\n"))
    }

    @Test("The time window is stored as dashboardGraphWindow")
    func window() async throws {
        let world = try await DashboardWorld()
        defer { Task { await world.close() } }
        world.store.setWindow(.day, of: "ORD")
        #expect(world.store.window(of: "ORD") == .day)
        await world.store.settle()
        #expect(try world.text.hasSuffix("dashboardGraphWindow: day\n"))
        #expect(world.store.window(of: "ORD") == .day)
    }

    @Test("A change that breaks a rule shows why, the stored list shows again, and the next change clears the message")
    func failure() async throws {
        let world = try await DashboardWorld(extra: v2Widgets)
        defer { Task { await world.close() } }
        var widgets = try #require(world.store.widgets(of: "ORD"))
        widgets[1].title = String(repeating: "x", count: 101)
        world.store.setWidgets(widgets, of: "ORD")
        await world.store.settle()
        #expect(world.store.failure(of: "ORD") == "dashboardWidgets[1]: use a title of at most 100 characters on one line.")
        #expect(world.store.widgets(of: "ORD")?[1].title == "Work")
        world.store.setWindow(.hour, of: "ORD")
        #expect(world.store.failure(of: "ORD") == nil)
        await world.store.settle()
    }

    @Test("A change made elsewhere shows at once")
    func outsideChange() async throws {
        let world = try await DashboardWorld()
        defer { Task { await world.close() } }
        let id = UUID()
        try await world.session.update("ORD", ProjectChange(dashboardWidgets: [DashboardWidgetEntry(id: id, kind: .project, fields: [.name])]))
        #expect(world.store.widgets(of: "ORD") == [DashboardWidget(id: id, kind: .project, fields: [.name], statuses: [.created, .inProgress, .inReview, .done])])
    }

    @Test("Widgets map to the file and back without loss")
    func mapping() {
        let entry = DashboardWidgetEntry(id: UUID(), kind: .tickets, title: " Mine ", column: 1, row: 2, width: 3, height: 4,
                                         statuses: [.done, .draft], includeSubprojects: false,
                                         unknownKeys: ["x": RawYAML.scalar(.init("1"))])
        let widget = LiveDashboardStore.widget(entry)
        #expect(widget.statuses == [.done, .draft])
        #expect(LiveDashboardStore.entries([widget], merging: [entry]) == [entry])
        #expect(LiveDashboardStore.entries([widget], merging: []).first?.unknownKeys == [:])
    }
}

@Suite("Widgets of unavailable tools")
@MainActor
struct DashboardAvailabilityTests {
    private let orders = Project.sample("ORD")!

    @Test("A widget shows once its tool is available; Recent Chats and Cost never show")
    func shown() {
        let tickets: Set<ToolKind> = [.dashboard, .tickets]
        #expect(DashboardWidgetKind.shown(for: orders, tools: tickets) == [.project, .tickets])
        #expect(DashboardWidgetKind.addable(for: orders, tools: tickets) == [.project, .tickets])
        let all = Set(ToolKind.allCases)
        #expect(!DashboardWidgetKind.shown(for: orders, tools: all).contains(.recentChats))
        #expect(!DashboardWidgetKind.shown(for: orders, tools: all).contains(.cost))
        #expect(DashboardWidgetKind.shown(for: orders, tools: all).contains(.serviceGraph))
    }

    @Test("While the graph is off, the graph widgets are hidden and not offered; Instances stays")
    func graphOff() {
        func service(graph: Bool) -> Project {
            Project(id: "SVC", name: "Service", kind: .service, tint: .accent, symbol: "server.rack", path: "/p/svc", repository: "",
                    environments: [DeploymentEnvironment(name: "production", cluster: nil, namespace: "svc", url: nil, health: nil)],
                    activity: nil, environmentsAreResolved: true, graphEnabled: graph)
        }
        let all = Set(ToolKind.allCases)
        let off = service(graph: false)
        #expect(!DashboardWidgetKind.showsGraph(off))
        #expect(DashboardWidgetKind.hasServiceMap(off))
        #expect(DashboardWidgetKind.shown(for: off, tools: all) == [.project, .tickets, .recentBuilds, .instances])
        #expect(!DashboardWidgetKind.addable(for: off, tools: all).contains(.serviceGraph))
        #expect(DashboardWidget.defaultList(for: off).map(\.kind) == [.project, .tickets, .recentBuilds])
        let on = service(graph: true)
        #expect(DashboardWidgetKind.shown(for: on, tools: all).isSuperset(of: [.serviceGraph, .busiestCalls, .failedRequests, .requestsPerMinute]))
        #expect(DashboardWidget.defaultList(for: on).map(\.kind) == [.project, .tickets, .recentBuilds, .serviceGraph])
    }

    @Test("Hidden widgets take no place and keep their stored positions through a change")
    func hiddenKeepTheirPlace() {
        let graph = DashboardWidget(id: UUID(), kind: .serviceGraph, column: 0, row: 0, width: 24, height: 6)
        let project = DashboardWidget(id: UUID(), kind: .project, column: 0, row: 6, width: 12, height: 4)
        let store = MockDashboardLayoutStore(["ORD": DashboardLayout(widgets: [graph, project])])
        let model = DashboardModel(project: orders, store: store, tools: [.dashboard, .tickets], editing: true)
        model.areaWidth = 1000
        #expect(model.cells(of: DashboardSlot.slots(of: model.widgets)[1])?.row == 0, "The Project widget rises into the map's place")
        model.update(DashboardSlot.slots(of: model.widgets)[1]) { $0.title = "Here" }
        #expect(model.widgets[0].cells == graph.cells)
        #expect(!model.showsTimeWindow)
        #expect(!model.showsEnvironment)
    }
}
