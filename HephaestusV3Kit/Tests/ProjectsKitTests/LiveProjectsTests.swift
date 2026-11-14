import Foundation
import ProjectData
import Testing
import ToolsFoundation
@testable import ProjectsKit

@Suite("Projects from the app's data")
struct ProjectMappingTests {
    private func loaded(_ file: ProjectFile, root: String = "/p/orders", parentID: String? = nil,
                        resolved: ResolvedSettings = ResolvedSettings()) -> LoadedProject {
        LoadedProject(root: root, file: file, parentID: parentID, depth: parentID == nil ? 0 : 1, childIDs: [], resolved: resolved,
                      fileIssue: nil)
    }

    @Test("V2's types become V3's kinds, and back")
    func kinds() {
        #expect(ProjectKind.allCases.map { Project.Kind($0) } == [.other, .service, .app, .library])
        #expect(Project.Kind.allCases.map(\.stored) == [.goService, .swiftApplication, .library, .none])
    }

    @Test("A tint name gives its tint; V2's colors the nearest hue; none or a gray gives Accent")
    func tints() {
        #expect(ProjectTint(stored: "info") == .info)
        #expect(ProjectTint(stored: nil) == .accent)
        #expect(ProjectTint(stored: "#34C759") == .success)
        #expect(ProjectTint(stored: "#FF9500") == .warning)
        #expect(ProjectTint(stored: "#AF52DE") == .accent)
        #expect(ProjectTint(stored: "#FF2D55") == .accentSecondary)
        #expect(ProjectTint(stored: "#32ADE6") == .info)
        #expect(ProjectTint(stored: "#8E8E93") == .accent)
    }

    @Test("A loaded project keeps its settings as they apply, and reports no tool figures")
    func project() {
        var resolved = ResolvedSettings()
        resolved.environments = [EnvironmentEntry(name: "local", url: "http://127.0.0.1", port: 8080),
                                 EnvironmentEntry(name: "replay", namespace: "orders")]
        resolved.inheritedEnvironments = [EnvironmentEntry(name: "local")]
        resolved.currentEnvironment = "replay"
        resolved.githubPage = "https://github.com/example/worker"
        let file = ProjectFile(id: "WRK", name: "Worker", created: Date(timeIntervalSince1970: 0), type: .goService, icon: "gearshape")
        let project = Project(loaded(file, root: "/p/orders/worker", parentID: "ORD", resolved: resolved))
        #expect(project.kind == .service)
        #expect(project.symbol == "gearshape")
        #expect(project.path == "/p/orders/worker")
        #expect(project.repository == "example/worker")
        #expect(project.activity == nil)
        #expect(project.environmentsAreResolved)
        #expect(project.environments.map(\.inheritedFrom) == ["ORD", nil])
        #expect(project.environments[0].url == "http://127.0.0.1:8080")
        #expect(project.environments[0].health == nil)
        #expect(project.currentEnvironment == "replay")
        #expect(ProjectTree([project]).environments(of: "WRK").map(\.name) == ["local", "replay"])
    }
}

@Suite("New Project")
struct NewProjectModelTests {
    private let developer = URL(fileURLWithPath: "/Users/someone/Developer", isDirectory: true)

    @Test("The identifier and the folder name follow the name until the user edits them")
    func following() {
        let model = NewProjectModel(projects: [], location: developer)
        model.name = "Orders: API/v2"
        #expect(model.identifier == "ORDE")
        #expect(model.folderName == "Orders- API-v2")
        model.setIdentifier("ord")
        model.setFolderName("orders")
        model.name = "Something Else"
        #expect(model.identifier == "ORD")
        #expect(model.folderName == "orders")
        #expect(model.projectFolder == "/Users/someone/Developer/orders")
    }

    @Test("The rules: name, identifier format and use, folder name, existing folder")
    func rules() {
        let orders = MockProjectStore().projects.first { $0.id == "A" }!
        let model = NewProjectModel(projects: [orders], location: developer)
        #expect(model.request == nil)
        #expect(model.identifierMessage == nil)
        model.name = "A"
        #expect(model.identifierMessage == nil)
        model.setIdentifier("A")
        #expect(model.identifierMessage == "Use 2 to 8 letters (A–Z).")
        model.setIdentifier("")
        #expect(model.identifierMessage == "Enter an identifier.")
        model.name = "Alpha"
        model.setIdentifier("alpha")
        #expect(model.identifierMessage == nil)
        model.setFolderName(".hidden")
        #expect(model.folderMessage == "Enter a folder name without “/” that does not start with “.”.")
        model.setFolderName("alpha")
        model.folderMode = .existingFolder
        #expect(model.folderMessage == "Choose a folder.")
        model.folderMode = .newFolder
        let request = model.request
        #expect(request == NewProject(name: "Alpha", identifier: "ALPHA", kind: .none, folder: "/Users/someone/Developer/alpha",
                                      createsFolder: true, parentID: nil))
    }

    @Test("The type follows go.mod; the parent follows the folder until the user picks one")
    func followsTheFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ProjectsKitTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = root.appendingPathComponent("orders/api", isDirectory: true)
        try FileManager.default.createDirectory(at: service, withIntermediateDirectories: true)
        try Data("module example.com/api\n".utf8).write(to: service.appendingPathComponent("go.mod"))
        let parent = MockProjectStore.project("ORD", "Orders", .service)
        let orders = Project(id: "ORD", name: "Orders", kind: .service, tint: .accent, symbol: "folder",
                             path: root.appendingPathComponent("orders").path, repository: "", activity: nil)
        _ = parent
        let model = NewProjectModel(projects: [orders], location: root.appendingPathComponent("orders", isDirectory: true))
        model.name = "API"
        model.setFolderName("api")
        #expect(model.kind == .service)
        #expect(model.parentID == "ORD")
        #expect(model.insideProject == nil)
        model.pickParent(nil)
        #expect(model.parentID == nil)
        #expect(model.insideProject?.id == "ORD")
        model.pickedKind = .library
        model.setFolderName("other")
        #expect(model.kind == .library)
    }

    @Test("A sub project's folder must be inside its parent's")
    func subProject() {
        let shop = Project(id: "SHOP", name: "Shop", kind: .service, tint: .accent, symbol: "folder", path: "/p/shop", repository: "",
                           activity: nil)
        let model = NewProjectModel(projects: [shop], location: developer, parentID: "SHOP")
        #expect(model.isSubProject)
        #expect(model.location.path == "/p/shop")
        model.name = "Cart"
        #expect(model.parentID == "SHOP")
        #expect(model.request?.folder == "/p/shop/Cart")
        model.location = developer
        #expect(model.folderMessage == "Choose a folder inside “Shop”.")
    }

    @Test("A new project's folder goes beside the selected project's top-level folder, else in ~/Developer")
    func defaultLocation() {
        let alpha = Project(id: "A", name: "Alpha", kind: .service, tint: .accent, symbol: "folder", path: "/p/alpha", repository: "",
                            activity: nil)
        let one = Project(id: "A1", name: "One", kind: .service, tint: .accent, symbol: "folder", path: "/p/alpha/one", repository: "",
                          activity: nil, parentID: "A")
        let tree = ProjectTree([alpha, one])
        #expect(NewProjectModel.defaultLocation(selected: one, in: tree).path == "/p")
        #expect(NewProjectModel.defaultLocation(selected: nil, in: tree, home: "/nonexistent").path == "/nonexistent")
    }
}

@Suite("Projects window on the app's data")
struct LiveProjectsWindowTests {
    @Test("Loading, failure and an empty list are states of their own")
    func states() {
        var store = MockProjectStore()
        store.state = .loading
        #expect(!ProjectsModel(store: store).isEmpty)
        let empty = ProjectsModel(store: SampleProjectStore(projects: []))
        #expect(empty.isEmpty)
        let unavailable = ProjectsModel(store: SampleProjectStore(projects: [], unavailable: [
            ProjectDirectory.Unavailable(path: "/p/gone", reason: "The folder is missing.", parentID: nil),
        ]))
        #expect(!unavailable.isEmpty)
        #expect(unavailable.unavailable.count == 1)
    }

    @Test("A removed project leaves the selection to its nearest listed ancestor, else to the first project")
    func keepSelection() {
        let all = MockProjectStore().projects
        let directory = ProjectDirectory(projects: all)
        let model = ProjectsModel(store: DirectoryProjectStore(directory: directory), selection: "A1L")
        model.select("A1L")
        directory.update(projects: all.filter { $0.id != "A1L" && $0.id != "A1" }, state: .ready, unavailable: [])
        model.keepSelection()
        #expect(model.selection == "A")
        model.select("B")
        directory.update(projects: all.filter { $0.id != "B" && $0.parentID != "B" }, state: .ready, unavailable: [])
        model.keepSelection()
        #expect(model.selection == "A")
    }

    @Test("Once the projects load, the first one is selected")
    func firstSelection() {
        let directory = ProjectDirectory(projects: [], state: .loading)
        let model = ProjectsModel(store: DirectoryProjectStore(directory: directory))
        directory.update(projects: MockProjectStore().projects, state: .ready, unavailable: [])
        model.keepSelection()
        #expect(model.selection == "A")
    }
}
