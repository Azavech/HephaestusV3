import AZDesign
import Foundation
import MachineData
import Observation
import ToolsFoundation

/// What the Virtual Machines window shows.
nonisolated enum MachineSelection: Hashable, Sendable {
    case machine(VirtualMachine.ID)
    case image(MachineImage.ID)
}

/// What the detail area shows for a selection.
nonisolated enum MachineDetailContent: Equatable, Sendable {
    case machine(VirtualMachine)
    case image(MachineImage)
    /// A route named a machine that isn't on this Mac.
    case machineNotFound(VirtualMachine.ID)
    /// Nothing is selected.
    case nothing
}

/// The Virtual Machines window: its selection, what a route's focus selects, and which panes show in
/// the layout its width picks.
@Observable
final class MachinesModel {
    /// The width the sidebar, the screen and the inspector need side by side: the sidebar and the
    /// inspector at their default widths, 250 and 300 points, leave the screen 350.
    static let macWidth: CGFloat = 900

    let store: any MachineStore
    var selection: MachineSelection?
    /// The sheet over the window.
    var sheet: MachineSheet?
    /// A failed action's alert.
    var alert: MachineAlert?
    /// Items an action is under way on: their buttons are disabled meanwhile.
    private(set) var busy: Set<String> = []
    /// A machine or image waiting for Delete's confirmation.
    var pendingDeletion: MachineSelection?
    /// Opened on a machine a route named: an iPhone's layout starts on its page.
    let opensSelection: Bool

    /// The layout the window's width picks. The Mac's until the window is measured.
    private(set) var layout: WindowLayout = .mac
    /// Whether the sidebar shows beside the detail. An iPad's folds it while the inspector shows.
    private(set) var showsSidebar = true
    /// Whether the inspector shows beside the machine's screen. An iPad's folds it away at first.
    private(set) var showsInspector = true
    /// An iPhone's shows the inspector as a sheet over the machine's page.
    var showsInspectorSheet = false

    /// The machines, with `focus` (a machine id) selected, or the first machine without one.
    convenience init(focus: String?, store: any MachineStore) {
        let machines = store.machines
        self.init(
            store: store,
            selection: (focus ?? machines.first?.id).map(MachineSelection.machine),
            opensSelection: focus != nil
        )
    }

    init(store: any MachineStore, selection: MachineSelection?, opensSelection: Bool = false) {
        self.store = store
        self.selection = selection
        self.opensSelection = opensSelection
    }

    /// The Mac's machines, as the store has them now.
    var machines: [VirtualMachine] { store.machines }
    /// The images, as the store has them now.
    var images: [MachineImage] { store.images }

    func image(_ id: MachineImage.ID?) -> MachineImage? { images.first { $0.id == id } }
    func machine(_ id: VirtualMachine.ID?) -> VirtualMachine? { machines.first { $0.id == id } }

    // MARK: Actions

    /// Runs an action on an item, its buttons disabled until it ends; a failure shows `title`'s alert.
    func perform(_ id: String, _ title: String, _ action: @escaping @MainActor () async throws -> Void) {
        guard !busy.contains(id) else { return }
        busy.insert(id)
        Task {
            defer { busy.remove(id) }
            do {
                try await action()
            } catch {
                alert = MachineAlert(title: title, message: error.localizedDescription)
            }
        }
    }

    func isBusy(_ id: String) -> Bool { busy.contains(id) }

    func start(_ machine: VirtualMachine) {
        perform(machine.id, String(localized: "Start failed", bundle: #bundle)) { [store] in
            if machine.state == .paused { try await store.resume(machine.id) } else { try await store.start(machine.id) }
        }
    }

    func stop(_ machine: VirtualMachine) {
        perform(machine.id, String(localized: "Stop failed", bundle: #bundle)) { [store] in try await store.stop(machine.id) }
    }

    func pause(_ machine: VirtualMachine) {
        perform(machine.id, String(localized: "Pause failed", bundle: #bundle)) { [store] in try await store.pause(machine.id) }
    }

    /// Deletes the item waiting for confirmation; the selection moves to the first machine.
    func confirmDeletion() {
        guard let pending = pendingDeletion else { return }
        pendingDeletion = nil
        switch pending {
        case .machine(let id):
            perform(id, String(localized: "Delete failed", bundle: #bundle)) { [store] in try await store.deleteMachine(id) }
        case .image(let id):
            perform(id, String(localized: "Delete failed", bundle: #bundle)) { [store] in try await store.deleteImage(id) }
        }
        // The next selection survives the deletion: an image takes its machines with it.
        if selection == pending {
            selection = switch pending {
            case .machine: machines.first { .machine($0.id) != pending }.map { .machine($0.id) }
            case .image(let id): machines.first { $0.imageID != id }.map { .machine($0.id) }
            }
        }
    }

    /// The failure a machine or setup stopped with, shown once.
    func showFailures() {
        guard alert == nil, let (id, message) = store.failures.first else { return }
        store.clearFailure(id)
        let name = machine(id)?.name ?? image(id)?.name ?? id
        alert = MachineAlert(title: String(localized: "\(name) stopped", bundle: #bundle, comment: "Alert title: a virtual machine stopped with a failure"),
                             message: message)
    }

    // MARK: Selection

    /// Selects the machine a route names, in a window that is already open: again, if the user has
    /// picked another item since.
    func select(focus: String) {
        selection = .machine(focus)
    }

    /// What the detail area shows for the current selection.
    var content: MachineDetailContent {
        content(of: selection)
    }

    /// What the detail area, or an iPhone's page, shows for `selection`.
    func content(of selection: MachineSelection?) -> MachineDetailContent {
        switch selection {
        case .machine(let id)?:
            machines.first { $0.id == id }.map(MachineDetailContent.machine) ?? .machineNotFound(id)
        case .image(let id)?:
            images.first { $0.id == id }.map(MachineDetailContent.image) ?? .nothing
        case nil:
            .nothing
        }
    }

    // MARK: Layout

    /// Picks the layout for a window `width` points wide (see `apply(_:)`).
    func resize(to width: CGFloat) {
        apply(WindowLayout.forWidth(width, macWidth: Self.macWidth))
    }

    /// Takes the window's layout. A new layout shows its panes afresh: a Mac's sidebar and inspector,
    /// an iPad's sidebar with the inspector folded away.
    func apply(_ layout: WindowLayout) {
        guard layout != self.layout else { return }
        self.layout = layout
        showsSidebar = true
        showsInspector = layout == .mac
        showsInspectorSheet = false
    }

    /// Whether the inspector's button reads Hide: the inspector shows, beside the screen or as a sheet.
    var isInspectorShown: Bool {
        layout == .phone ? showsInspectorSheet : showsInspector
    }

    /// The inspector's button: shows or hides the inspector, or opens its sheet on an iPhone's page.
    func toggleInspector() {
        if layout == .phone {
            showsInspectorSheet.toggle()
        } else {
            setInspectorShown(!showsInspector)
        }
    }

    /// Shows or hides the inspector. An iPad's has no room for the sidebar beside it, so it folds the
    /// sidebar away.
    func setInspectorShown(_ shown: Bool) {
        showsInspector = shown
        if shown, layout == .pad {
            showsSidebar = false
        }
    }

    /// Shows or hides the sidebar. An iPad's has no room for the inspector beside it, so it folds the
    /// inspector away.
    func setSidebarShown(_ shown: Bool) {
        showsSidebar = shown
        if shown, layout == .pad {
            showsInspector = false
        }
    }
}

extension MachinesModel {
    /// The sample machines with `selection` picked, for the previews.
    static func preview(_ selection: MachineSelection?, opensSelection: Bool = false) -> MachinesModel {
        MachinesModel(store: SampleMachineStore(), selection: selection, opensSelection: opensSelection)
    }

    /// The sample machines, opened on `focus` as a route would, for the previews.
    static func sample(focus: String? = nil) -> MachinesModel {
        MachinesModel(focus: focus, store: SampleMachineStore())
    }
}

/// A sheet of the Virtual Machines window.
nonisolated enum MachineSheet: Identifiable, Hashable, Sendable {
    /// New Machine, with an image chosen or not.
    case newMachine(imageID: MachineImage.ID?)
    case editMachine(VirtualMachine.ID)
    case addImage
    case shell(VirtualMachine.ID)

    var id: String {
        switch self {
        case .newMachine(let image): "new.\(image ?? "")"
        case .editMachine(let id): "edit.\(id)"
        case .addImage: "addImage"
        case .shell(let id): "shell.\(id)"
        }
    }
}

/// A failed action: its title and the store's message.
nonisolated struct MachineAlert: Identifiable, Hashable, Sendable {
    let id = UUID()
    let title: String
    let message: String
}
