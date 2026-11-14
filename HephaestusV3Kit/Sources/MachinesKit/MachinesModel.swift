import Foundation
import Observation
import ToolsFoundation

/// Where the machines and images come from. The app and the previews use `SampleMachineStore`.
protocol MachineStore {
    /// The Mac's virtual machines, in the order the list shows them.
    func machines() -> [VirtualMachine]
    /// The system images new machines start from, in the order the list shows them.
    func images() -> [MachineImage]
}

/// The sample machines and images, or others for a preview.
struct SampleMachineStore: MachineStore {
    private let sampleMachines: [VirtualMachine]
    private let sampleImages: [MachineImage]

    init(machines: [VirtualMachine] = VirtualMachine.samples, images: [MachineImage] = MachineImage.samples) {
        sampleMachines = machines
        sampleImages = images
    }

    func machines() -> [VirtualMachine] { sampleMachines }
    func images() -> [MachineImage] { sampleImages }
}

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

    let machines: [VirtualMachine]
    let images: [MachineImage]
    var selection: MachineSelection?
    /// Opened on a machine a route named: an iPhone's layout starts on its page.
    let opensSelection: Bool

    /// The layout the window's width picks. The Mac's until the window is measured.
    private(set) var layout: ToolLayout = .mac
    /// Whether the sidebar shows beside the detail. An iPad's folds it while the inspector shows.
    private(set) var showsSidebar = true
    /// Whether the inspector shows beside the machine's screen. An iPad's folds it away at first.
    private(set) var showsInspector = true
    /// An iPhone's shows the inspector as a sheet over the machine's page.
    var showsInspectorSheet = false

    /// The machines, with `focus` (a machine id) selected, or the first machine without one.
    convenience init(focus: String?, store: any MachineStore) {
        let machines = store.machines()
        self.init(
            store: store,
            selection: (focus ?? machines.first?.id).map(MachineSelection.machine),
            opensSelection: focus != nil
        )
    }

    init(store: any MachineStore, selection: MachineSelection?, opensSelection: Bool = false) {
        machines = store.machines()
        images = store.images()
        self.selection = selection
        self.opensSelection = opensSelection
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

    /// Picks the layout for a window `width` points wide. A new layout shows its panes afresh: a
    /// Mac's sidebar and inspector, an iPad's sidebar with the inspector folded away.
    func resize(to width: CGFloat) {
        let layout = ToolLayout.forWidth(width, macWidth: Self.macWidth)
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
}
