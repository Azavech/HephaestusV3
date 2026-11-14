import Foundation
import Testing
@testable import ProjectsKit
import ToolsFoundation

@Suite("Project lists")
struct ProjectListTests {
    let tree = ProjectTree(MockProjectStore().projects)

    private func ids(_ sections: [ProjectListSection]) -> [Project.Kind: [String]] {
        Dictionary(uniqueKeysWithValues: sections.map { ($0.kind, $0.entries.map { "\($0.project.id)@\($0.depth)" }) })
    }

    @Test("Without a filter, sub projects follow their parent in their top-level project's section")
    func treeOrder() {
        let sections = tree.sections(matching: "")
        #expect(sections.map(\.kind) == [.service, .app, .library])
        #expect(ids(sections) == [
            .service: ["A@0", "A1@1", "A1L@2", "A2@1"],
            .app: ["B@0", "BK@1"],
            .library: ["C@0"],
        ])
    }

    @Test("While filtering, the matches are flat, each in its own kind's section")
    func filtered() {
        #expect(ids(tree.sections(matching: "kit")) == [.library: ["BK@0"]])
        #expect(ids(tree.sections(matching: "one")) == [.service: ["A1@0"], .library: ["A1L@0"]])
    }

    @Test("The filter matches names and identifiers, ignoring case and diacritics")
    func matching() {
        #expect(tree.matching("beta").map(\.id) == ["B", "BK"])
        #expect(tree.matching("ALPHA T").map(\.id) == ["A2"])
        #expect(tree.matching("a1").map(\.id) == ["A1", "A1L"])
    }

    @Test("Spaces alone don't filter")
    func blankQuery() {
        #expect(tree.sections(matching: "  ") == tree.sections(matching: ""))
    }
}

@Suite("Projects window")
struct ProjectsModelTests {
    @Test("The sidebar lists the top-level projects by kind; their rows hold the sub projects")
    func sidebar() {
        let model = ProjectsModel(store: MockProjectStore(), selection: "A1")
        #expect(model.sidebarSections.map { $0.entries.map(\.project.id) } == [["A"], ["B"], ["C"]])
        #expect(model.children(of: "A").map(\.id) == ["A1", "A2"])
        #expect(model.selectedProject?.id == "A1")
    }

    @Test("Filtering lists the matches alone and keeps the selection")
    func filtering() {
        let model = ProjectsModel(store: MockProjectStore(), selection: "A1")
        model.query = "kit"
        #expect(model.isFiltering)
        #expect(model.sidebarSections.map { $0.entries.map(\.project.id) } == [["BK"]])
        #expect(model.selection == "A1")
        #expect(!model.hasNoMatches)
        model.query = "xyz"
        #expect(model.hasNoMatches)
        #expect(model.sidebarSections.isEmpty)
    }

    @Test("Selecting a sub project unfolds its parents, and only them")
    func selectRevealsRow() {
        let model = ProjectsModel(store: MockProjectStore(), selection: "C")
        model.setExpanded(false, "A")
        model.setExpanded(false, "A1")
        model.setExpanded(false, "B")
        model.select("A1L")
        #expect(model.selection == "A1L")
        #expect(model.isExpanded("A"))
        #expect(model.isExpanded("A1"))
        #expect(!model.isExpanded("B"))
    }

    @Test("Selecting the selected project again shows its row after its parent was folded")
    func reselectRevealsRow() {
        let model = ProjectsModel(store: MockProjectStore(), selection: "BK")
        model.setExpanded(false, "B")
        model.select("BK")
        #expect(model.isExpanded("B"))
    }

    @Test("A route's focus selects the project it names, and nothing else")
    func focus() {
        let model = ProjectsModel(store: MockProjectStore(), selection: "A")
        model.select(focus: "BK")
        #expect(model.selection == "BK")
        model.select(focus: "NOPE")
        #expect(model.selection == "BK")
    }

    @Test("A sub project lists its parent's environments, then its own whose names they don't have")
    func inheritedEnvironments() {
        let model = ProjectsModel(store: MockProjectStore())
        let own = model.environments(of: "A")
        #expect(own.environments.map(\.name) == ["Staging", "Production"])
        #expect(own.inheritedFrom == nil)

        let inherited = model.environments(of: "A1")
        #expect(inherited.environments.map(\.name) == ["Staging", "Production", "Own"])
        #expect(inherited.environments.map(\.inheritedFrom) == ["A", "A", nil])
        #expect(inherited.inheritedFrom?.id == "A")

        // Up the tree: A1L inherits A1's, which come from A and A1.
        #expect(model.environments(of: "A1L").inheritedFrom?.id == "A1")
        #expect(model.environments(of: "A1L").environments.map(\.name) == ["Staging", "Production", "Own"])

        // An own environment named like an inherited one isn't used.
        let separate = model.environments(of: "A2")
        #expect(separate.environments.map(\.name) == ["Staging", "Production", "Separate"])
        #expect(separate.environments[0].namespace == "a")

        #expect(model.environments(of: "BK").environments.isEmpty)
    }

    @Test("Orders lists Shop's environments, with the note naming Shop")
    func sampleInheritance() {
        let model = ProjectsModel(store: SampleProjectStore())
        let environments = model.environments(of: "ORD")
        #expect(environments.inheritedFrom?.id == "SHOP")
        #expect(environments.environments.map(\.url) == Project.sample("SHOP")?.environments.map(\.url))
    }

    @Test("Figures and activity include the sub projects")
    func family() {
        let store = MockProjectStore(events: [
            "A": [MockProjectStore.event(.builds, "#3", minutesAgo: 30)],
            "A1": [MockProjectStore.event(.tickets, "A1-1", minutesAgo: 5)],
            "A1L": [MockProjectStore.event(.builds, "#9", minutesAgo: 60)],
            "B": [MockProjectStore.event(.tickets, "B-1", minutesAgo: 1)],
        ])
        let model = ProjectsModel(store: store)
        #expect(model.ticketTotals(of: "A") == (open: 4, inReview: 4, drafts: 4))
        #expect(model.descendantCount(of: "A") == 3)
        #expect(model.activity(of: "A").map(\.id) == ["A1.tickets.A1-1", "A.builds.3", "A1L.builds.9"])
        #expect(model.activity(of: "A1L").map(\.id) == ["A1L.builds.9"])
    }

    @Test("The activity lists at most 40 events")
    func activityLimit() {
        let events = (0..<50).map { MockProjectStore.event(.builds, "#\($0)", minutesAgo: $0) }
        let model = ProjectsModel(store: MockProjectStore(events: ["C": events]))
        #expect(model.activity(of: "C").count == ProjectsModel.activityLimit)
        #expect(model.activity(of: "C").first?.item.subject == "#0")
    }
}

@Suite("Overview grids")
struct OverviewGridTests {
    private func columns(_ count: Int, minimum: CGFloat, width: CGFloat) -> Int {
        OverviewGrid.columnCount(for: count, minimum: minimum, spacing: 14, width: width)
    }

    @Test("Six tools: 6, 3, 2, 1 columns")
    func sixTools() {
        #expect(columns(6, minimum: 220, width: 1_390) == 6)
        #expect(columns(6, minimum: 220, width: 1_000) == 3)
        #expect(columns(6, minimum: 220, width: 600) == 2)
        #expect(columns(6, minimum: 220, width: 300) == 1)
    }

    @Test("Five tools: 5, 3, 2, 1 columns, the fewest empty places when nothing divides")
    func fiveTools() {
        #expect(columns(5, minimum: 220, width: 1_156) == 5)
        #expect(columns(5, minimum: 220, width: 1_000) == 3)
        #expect(columns(5, minimum: 220, width: 700) == 3)
        #expect(columns(5, minimum: 220, width: 600) == 2)
        #expect(columns(5, minimum: 220, width: 300) == 1)
    }

    @Test("Four tools: 4, 2, 1 columns")
    func fourTools() {
        #expect(columns(4, minimum: 220, width: 922) == 4)
        #expect(columns(4, minimum: 220, width: 800) == 2)
        #expect(columns(4, minimum: 220, width: 300) == 1)
    }

    @Test("Three cards: 3, then 1 column")
    func threeCards() {
        #expect(columns(3, minimum: 240, width: 748) == 3)
        #expect(columns(3, minimum: 240, width: 600) == 1)
    }

    @Test("Before the overview is measured, one column")
    func unmeasured() {
        #expect(columns(6, minimum: 220, width: 0) == 1)
    }
}

@Suite("Activity samples")
struct ActivitySampleTests {
    @Test("Each sample project's events have ids of their own", arguments: ["ORD", "PAY", "GW", "TLS", "AZD", "SHOP", "TKIT"])
    func uniqueIDs(projectID: Project.ID) {
        let ids = SampleProjectStore().activity(of: projectID).map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("An event's id is its tool and subject")
    func id() {
        let first = ActivityItem.samples(for: "ORD").first
        #expect(first?.id == "builds.1288")
        #expect(first?.route(in: "ORD") == .tool(.builds, project: "ORD", focus: "1288"))
    }

    @Test("The sample store lists the sample projects")
    func store() {
        #expect(SampleProjectStore().projects.map(\.id) == Project.samples.map(\.id))
    }

    @Test("The overview's graph shows the current environment of a service whose graph is on")
    func graphEnvironment() {
        let model = ProjectsModel(store: SampleProjectStore())
        let all = Set(ToolKind.allCases)
        #expect(model.graphEnvironment(of: "SHOP", tools: all)?.name == "Local")
        #expect(model.graphEnvironment(of: "ORD", tools: all)?.name == "Local")
        #expect(model.graphEnvironment(of: "SHOP", tools: all.subtracting([.serviceMap])) == nil)
        // Tools has no graph on; AZDesign is a library.
        #expect(model.graphEnvironment(of: "TLS", tools: all) == nil)
        #expect(model.graphEnvironment(of: "AZD", tools: all) == nil)
        // Graph off: the mock store's services leave it off.
        #expect(ProjectsModel(store: MockProjectStore()).graphEnvironment(of: "A", tools: all) == nil)
    }

}
