import AZDesign
import Foundation
import MCPKit
import Testing
import ToolsFoundation
@testable import MachinesKit

/// Two machines and two images, in a fixed order, in a sample store.
@MainActor
func MockMachineStore(storedMachines: [VirtualMachine] = [.mock(id: "alpha", state: .running), .mock(id: "beta", state: .stopped)],
                      storedImages: [MachineImage] = [
                          MachineImage(id: "ready-image", name: "Ready image", system: .macOS, sizeGB: 18.4, state: .ready),
                          MachineImage(id: "new-image", name: "New image", system: .linux, sizeGB: 2, state: .downloading(progress: 0.25)),
                      ]) -> SampleMachineStore {
    SampleMachineStore(machines: storedMachines, images: storedImages, enforcesLimit: true)
}

extension VirtualMachine {
    static func mock(id: String, state: State) -> VirtualMachine {
        VirtualMachine(
            id: id, name: id.capitalized, system: .linux, systemVersion: "Ubuntu 26.04", state: state,
            cores: 2, memoryGB: 4, diskGB: 32, address: nil, projectID: nil, cpuUsage: 0, snapshots: []
        )
    }
}

@Suite("Machines window: selection and routes")
@MainActor
struct MachinesSelectionTests {
    @Test("A route's machine is selected when the window opens, and an iPhone's starts on its page")
    func focusAtOpening() {
        let model = MachinesModel(focus: "beta", store: MockMachineStore())
        #expect(model.selection == .machine("beta"))
        #expect(model.content == .machine(.mock(id: "beta", state: .stopped)))
        #expect(model.opensSelection)
    }

    @Test("Without a route's machine, the first machine is selected and an iPhone's starts on the list")
    func noFocus() {
        let model = MachinesModel(focus: nil, store: MockMachineStore())
        #expect(model.selection == .machine("alpha"))
        #expect(!model.opensSelection)
    }

    @Test("With no machines, nothing is selected")
    func noMachines() {
        let model = MachinesModel(focus: nil, store: MockMachineStore(storedMachines: []))
        #expect(model.selection == nil)
        #expect(model.content == .nothing)
    }

    @Test("A machine id that matches no machine shows a message, not a blank detail")
    func unknownMachine() {
        let model = MachinesModel(focus: "retired", store: MockMachineStore())
        #expect(model.content == .machineNotFound("retired"))
    }

    @Test("A second route to the same machine selects it again after the user picked another")
    func sameMachineRouteAgain() {
        let model = MachinesModel(focus: "alpha", store: MockMachineStore())
        model.selection = .machine("beta")
        model.select(focus: "alpha")
        #expect(model.selection == .machine("alpha"))
    }

    @Test("A route moves the selection from an image to its machine")
    func routeFromImage() {
        let model = MachinesModel(focus: nil, store: MockMachineStore())
        model.selection = .image("new-image")
        model.select(focus: "beta")
        #expect(model.selection == .machine("beta"))
    }

    @Test("A route to an unknown machine in an open window shows the message")
    func routeToUnknownMachine() {
        let model = MachinesModel(focus: nil, store: MockMachineStore())
        model.select(focus: "retired")
        #expect(model.content == .machineNotFound("retired"))
    }

    @Test("An image's page shows the image")
    func imageContent() {
        let store = MockMachineStore()
        let model = MachinesModel(store: store, selection: .image("ready-image"))
        #expect(model.content == .image(store.images[0]))
        #expect(model.content(of: .image("missing")) == .nothing)
        #expect(model.content(of: nil) == .nothing)
    }
}

@Suite("Machines window: layouts")
struct MachinesLayoutTests {
    @Test("Its Mac width is 900 points")
    func macWidth() {
        #expect(MachinesModel.macWidth == 900)
    }

    @Test("The width picks the layout", arguments: [
        (390.0, WindowLayout.phone), (639, .phone), (640, .pad), (899, .pad), (900, .mac), (2_560, .mac),
    ])
    func layout(width: Double, expected: WindowLayout) {
        let model = MachinesModel(focus: nil, store: MockMachineStore())
        model.resize(to: width)
        #expect(model.layout == expected)
    }

    @Test("A Mac's shows the sidebar and the inspector, each on its own")
    func macPanes() {
        let model = MachinesModel(focus: nil, store: MockMachineStore())
        model.resize(to: 1_100)
        #expect(model.showsSidebar && model.showsInspector)
        model.setSidebarShown(false)
        #expect(model.showsInspector)
        model.setSidebarShown(true)
        model.toggleInspector()
        #expect(model.showsSidebar && !model.showsInspector)
    }

    @Test("An iPad's folds the inspector behind its button")
    func padFoldsInspector() {
        let model = MachinesModel(focus: nil, store: MockMachineStore())
        model.resize(to: 760)
        #expect(model.showsSidebar)
        #expect(!model.showsInspector)
        #expect(!model.isInspectorShown)
    }

    @Test("An iPad's shows one side column at a time, so the screen keeps its room")
    func padOneSideColumn() {
        let model = MachinesModel(focus: nil, store: MockMachineStore())
        model.resize(to: 760)
        model.toggleInspector()
        #expect(model.showsInspector && !model.showsSidebar)
        model.setSidebarShown(true)
        #expect(model.showsSidebar && !model.showsInspector)
    }

    @Test("Widening to a Mac's shows both side columns again")
    func backToMac() {
        let model = MachinesModel(focus: nil, store: MockMachineStore())
        model.resize(to: 760)
        model.toggleInspector()
        model.resize(to: 1_100)
        #expect(model.showsSidebar && model.showsInspector)
    }

    @Test("An iPhone's shows the inspector as a sheet")
    func phoneSheet() {
        let model = MachinesModel(focus: nil, store: MockMachineStore())
        model.resize(to: 420)
        #expect(!model.isInspectorShown)
        model.toggleInspector()
        #expect(model.showsInspectorSheet)
        #expect(model.isInspectorShown)
        model.resize(to: 1_100)
        #expect(!model.showsInspectorSheet)
    }

    @Test("Resizing within a layout keeps the panes the user picked")
    func resizeWithinLayout() {
        let model = MachinesModel(focus: nil, store: MockMachineStore())
        model.resize(to: 1_100)
        model.toggleInspector()
        model.resize(to: 1_400)
        #expect(!model.showsInspector)
    }
}

@Suite("Machines: states and sizes")
struct MachineStateTests {
    @Test("A running machine offers Pause, Stop, Take Snapshot and Open Shell")
    func running() {
        let state = VirtualMachine.State.running
        #expect(state.isRunning)
        #expect(state.startAction == nil)
        #expect(state.allowsSnapshot)
        #expect(state.allowsShell)
    }

    @Test("A paused machine offers Resume and Take Snapshot, not Open Shell")
    func paused() {
        let state = VirtualMachine.State.paused
        #expect(!state.isRunning)
        #expect(state.startAction == .resume)
        #expect(state.allowsSnapshot)
        #expect(!state.allowsShell)
    }

    @Test("A stopped machine offers Start only")
    func stopped() {
        let state = VirtualMachine.State.stopped
        #expect(!state.isRunning)
        #expect(state.startAction == .start)
        #expect(!state.allowsSnapshot)
        #expect(!state.allowsShell)
    }

    @Test("Sizes are written with a unit formatter")
    func sizes() {
        let english = Locale(identifier: "en_US")
        #expect(StorageSize.formatted(gigabytes: 8, locale: english) == "8 GB")
        #expect(StorageSize.formatted(gigabytes: 18.4, fractionDigits: 1, locale: english) == "18.4 GB")
        // French writes its own unit, after a narrow no-break space.
        #expect(StorageSize.formatted(gigabytes: 8, locale: Locale(identifier: "fr_FR")) == "8\u{202F}Go")
    }

    @Test("An image's download reads as an amount out of its size")
    func downloadedSize() {
        let english = Locale(identifier: "en_US")
        let image = MachineImage(id: "beta", name: "Beta", system: .macOS, sizeGB: 18.9, state: .downloading(progress: 0.62))
        #expect(image.formattedSize(locale: english) == "18.9 GB")
        #expect(image.downloadedSize(locale: english) == "11.7 GB of 18.9 GB")
        let ready = MachineImage(id: "ready", name: "Ready", system: .macOS, sizeGB: 2.1, state: .ready)
        #expect(ready.downloadedSize(locale: english) == nil)
    }

    @Test("The sample machines have unique ids, and the first is Orders sandbox, which a route with no id selects")
    func samples() {
        let machines = SampleMachineStore().machines
        #expect(Set(machines.map(\.id)).count == machines.count)
        #expect(machines.first?.id == "orders-sandbox")
        let images = SampleMachineStore().images
        #expect(Set(images.map(\.id)).count == images.count)
    }
}

@Suite("Machines: actions")
@MainActor
struct MachineActionTests {
    @Test("Start, Pause, Resume and Stop go through the store; the list follows it")
    func lifecycle() async throws {
        let store = MockMachineStore()
        let model = MachinesModel(focus: "beta", store: store)
        let beta = try #require(model.machine("beta"))
        model.start(beta)
        try await waitUntil { model.machine("beta")?.state == .running }
        let running = try #require(model.machine("beta"))
        model.pause(running)
        try await waitUntil { model.machine("beta")?.state == .paused }
        model.start(try #require(model.machine("beta")))
        try await waitUntil { model.machine("beta")?.state == .running }
        model.stop(try #require(model.machine("beta")))
        try await waitUntil { model.machine("beta")?.state == .stopped }
    }

    @Test("A third machine can't start: the store refuses and the window shows its message")
    func limit() async throws {
        let store = MockMachineStore(storedMachines: [.mock(id: "a", state: .running), .mock(id: "b", state: .running), .mock(id: "c", state: .stopped)])
        #expect(!store.canStartAnother)
        let model = MachinesModel(focus: "c", store: store)
        model.start(try #require(model.machine("c")))
        try await waitUntil { model.alert != nil }
        #expect(model.alert?.message == "2 virtual machines are already running.")
        #expect(model.machine("c")?.state == .stopped)
    }

    @Test("Delete asks first, then deletes the machine and selects another")
    func deletion() async throws {
        let model = MachinesModel(focus: "alpha", store: MockMachineStore())
        model.pendingDeletion = .machine("alpha")
        #expect(model.machine("alpha") != nil)
        model.confirmDeletion()
        try await waitUntil { model.machine("alpha") == nil }
        #expect(model.pendingDeletion == nil)
        #expect(model.selection == .machine("beta"))
    }

    @Test("Deleting an image deletes its machines")
    func imageDeletion() async throws {
        var made = VirtualMachine.mock(id: "made", state: .stopped)
        made.imageID = "ready-image"
        let model = MachinesModel(store: MockMachineStore(storedMachines: [made]), selection: .image("ready-image"))
        model.pendingDeletion = .image("ready-image")
        model.confirmDeletion()
        try await waitUntil { model.image("ready-image") == nil }
        #expect(model.machines.isEmpty)
    }

    @Test("A machine that stopped with a failure shows its message once")
    func failures() {
        let store = SampleMachineStore(machines: [.mock(id: "alpha", state: .stopped)], images: [], failures: ["alpha": "The guest crashed."])
        let model = MachinesModel(focus: "alpha", store: store)
        model.showFailures()
        #expect(model.alert?.title == "Alpha stopped")
        #expect(model.alert?.message == "The guest crashed.")
        #expect(store.failures.isEmpty)
    }

    @Test("The guest account: an empty value removes it")
    func account() throws {
        let store = MockMachineStore()
        try store.setAccount("ready-image", userName: "tester", password: "secret")
        #expect(store.images[0].userName == "tester")
        #expect(store.images[0].hasPassword)
        #expect(store.password(ofImage: "ready-image") == "secret")
        try store.setAccount("ready-image", userName: nil, password: "")
        #expect(store.images[0].userName == "tester")
        #expect(!store.images[0].hasPassword)
    }

    @Test("Finish Setup needs the agent connected with SIP off, and nothing under way")
    func finishSetup() {
        #expect(ImageSetup(state: .running, agentConnected: true, sipOff: true, isRestarting: false).canFinish)
        #expect(!ImageSetup(state: .running, agentConnected: true, sipOff: false, isRestarting: false).canFinish)
        #expect(!ImageSetup(state: .running, agentConnected: false, sipOff: true, isRestarting: false).canFinish)
        #expect(!ImageSetup(state: .running, agentConnected: true, sipOff: true, isRestarting: true).canFinish)
        #expect(!ImageSetup(state: .stopping, agentConnected: true, sipOff: true, isRestarting: false).canFinish)
    }

    @Test("Starting and shutting down disable every action")
    func changing() {
        for state in [VirtualMachine.State.starting, .stopping] {
            #expect(state.isChanging)
            #expect(state.startAction == nil)
            #expect(!state.allowsShell)
            #expect(!state.allowsSnapshot)
        }
    }

    /// Waits up to 2 seconds for the store's task to finish.
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}

@Suite("Machine tools' paths on this Mac")
struct MachineToolPathTests {
    @Test("A path on this Mac is absolute or starts with ~/, expanded to the home folder")
    func macPath() throws {
        #expect(try MachineTools.macPath("/tmp/a", argument: "to") == "/tmp/a")
        #expect(try MachineTools.macPath("~/Downloads/a.txt", argument: "to", home: "/Users/x") == "/Users/x/Downloads/a.txt")
        #expect(throws: ToolError(.invalid, "from: use an absolute path or a path starting with ~/.")) {
            try MachineTools.macPath("a.txt", argument: "from")
        }
    }
}
