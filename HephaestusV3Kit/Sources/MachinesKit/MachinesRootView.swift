import AZDesign
import SwiftUI
import ToolsFoundation

/// The Virtual Machines window: the Mac's machines and images. It isn't tied to one project;
/// a machine can name the project it tests.
///
/// It adapts to its width as the tool windows do: a Mac's sidebar, screen and inspector side by side;
/// an iPad's with the inspector folded behind its button; an iPhone's one pane at a time.
/// What a tab keeps of Virtual Machines while another tab is in front: its model, so that its selection, filters
/// and drafts are still there when the tab comes back. The app's window makes one per tab and project.
@MainActor
public final class MachinesTabState {
    let model: MachinesModel

    public init(focus: String? = nil, store: LiveMachineStore) {
        model = MachinesModel(focus: focus, store: store)
    }
}

public struct MachinesRootView: View {
    /// The window's size, size classes and whether it narrowed from a regular width (AZDesign), which
    /// pick the Mac's, an iPad's or an iPhone's layout.
    @State private var adaptiveWindow = AdaptiveWindowState()
    @State private var model: MachinesModel

    /// No window gets narrower than an iPhone, or lower than the tool windows.
    private static let minimumSize = CGSize(width: 390, height: 420)

    /// The machines of `store`, with `focus` (a machine id) selected when the window opens. Routes that arrive
    /// later, while it is open, come as a `FocusRequest` in the environment.
    public init(focus: String? = nil, store: LiveMachineStore) {
        self.init(model: MachinesModel(focus: focus, store: store))
    }

    init(model: MachinesModel) {
        _model = State(initialValue: model)
    }

    /// The machines a tab keeps.
    public init(state: MachinesTabState) {
        self.init(model: state.model)
    }

    public var body: some View {
        Group {
            if model.layout == .phone {
                phoneBody
            } else {
                splitBody
            }
        }
        // Measures the window and gives its views their layout, size classes and whether it narrowed
        // from a regular width (AZDesign's adaptive window); the model shows the new layout's panes.
        .adaptiveWindow($adaptiveWindow, layout: adaptiveWindow.layout(macWidth: MachinesModel.macWidth))
        .onChange(of: adaptiveWindow.layout(macWidth: MachinesModel.macWidth), initial: true) { _, layout in
            model.apply(layout)
        }
        .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
        // A route to a machine while the window is open selects it, again if the user picked
        // another item since.
        .onFocusRequest { focus in
            model.select(focus: focus)
        }
        // File ▸ New Machine… (⇧⌘N), as the toolbar's New Machine.
        .newItemCommand(String(localized: "New Machine…", bundle: #bundle, comment: "File menu item, ⇧⌘N")) {
            model.sheet = .newMachine(imageID: nil)
        }
        .sheet(item: $model.sheet) { sheet in
            sheetContent(sheet)
        }
        .alert(model.alert?.title ?? "", isPresented: alertShown, presenting: model.alert) { _ in
            Button(String(localized: "OK", bundle: #bundle)) {}
        } message: { alert in
            Text(verbatim: alert.message)
        }
        .confirmationDialog(deletionTitle, isPresented: deletionShown, titleVisibility: .visible) {
            Button(String(localized: "Delete", bundle: #bundle), role: .destructive) { model.confirmDeletion() }
                .accessibilityIdentifier("machines.delete.confirm")
        } message: {
            Text(deletionMessage)
        }
        // A machine or setup that stops with a failure tells it once.
        .onChange(of: model.store.failures, initial: true) {
            model.showFailures()
        }
        .onChange(of: model.alert) {
            if model.alert == nil { model.showFailures() }
        }
    }

    @ViewBuilder private func sheetContent(_ sheet: MachineSheet) -> some View {
        switch sheet {
        case .newMachine(let imageID):
            NewMachineSheet(model: model, imageID: imageID)
        case .editMachine(let id):
            if let machine = model.machine(id) { EditMachineSheet(model: model, machine: machine) }
        case .addImage:
            AddImageSheet(model: model)
        case .shell(let id):
            if let machine = model.machine(id) { ShellSheet(model: model, machine: machine) }
        }
    }

    private var alertShown: Binding<Bool> {
        Binding { model.alert != nil } set: { if !$0 { model.alert = nil } }
    }

    private var deletionShown: Binding<Bool> {
        Binding { model.pendingDeletion != nil } set: { if !$0 { model.pendingDeletion = nil } }
    }

    private var deletionTitle: String {
        switch model.pendingDeletion {
        case .machine(let id)?:
            String(localized: "Delete “\(model.machine(id)?.name ?? id)”?", bundle: #bundle)
        case .image(let id)?:
            String(localized: "Delete “\(model.image(id)?.name ?? id)”?", bundle: #bundle)
        case nil:
            ""
        }
    }

    private var deletionMessage: String {
        switch model.pendingDeletion {
        case .image(let id)?:
            let count = model.machines.count { $0.imageID == id }
            return switch count {
            case 0: String(localized: "The image's folder and its disk are deleted, not moved to the Trash.", bundle: #bundle)
            case 1: String(localized: "The image and its machine are deleted, with their disks, not moved to the Trash.", bundle: #bundle)
            default: String(localized: "The image and its \(count) machines are deleted, with their disks, not moved to the Trash.", bundle: #bundle)
            }
        default:
            return String(localized: "A running machine stops at once. Its folder and disk are deleted, not moved to the Trash.", bundle: #bundle)
        }
    }

    /// A Mac's sidebar, screen and inspector; an iPad's with one side column at a time.
    private var splitBody: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            MachineList(model: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            detail(model.content)
        }
        .navigationTitle(String(localized: "Virtual Machines", bundle: #bundle))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                newMachineButton
            }
        }
    }

    /// An iPhone's: the list, then a machine or an image as a page with Back.
    private var phoneBody: some View {
        PhoneStack(selection: $model.selection, opensSelection: model.opensSelection) {
            MachineList(model: model)
                .navigationTitle(String(localized: "Virtual Machines", bundle: #bundle))
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        newMachineButton
                    }
                }
        } page: { selection in
            detail(model.content(of: selection))
        }
    }

    @ViewBuilder private func detail(_ content: MachineDetailContent) -> some View {
        switch content {
        case .machine(let machine):
            MachineDetail(machine: machine, model: model)
                .pageName(machine.name, layout: model.layout)
        case .image(let image):
            ImageDetail(image: image, model: model)
                .pageName(image.name, layout: model.layout)
        case .machineNotFound(let id):
            ContentUnavailableView {
                Label {
                    Text("Machine Not Found", bundle: #bundle)
                } icon: {
                    Image(systemName: "desktopcomputer.trianglebadge.exclamationmark")
                }
            } description: {
                Text("No machine on this Mac has the id “\(id)”.", bundle: #bundle)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.canvas)
            .accessibilityIdentifier("machines.notFound")
        case .nothing:
            ContentUnavailableView {
                Label {
                    Text("No Machine Selected", bundle: #bundle)
                } icon: {
                    Image(systemName: "desktopcomputer")
                }
            } description: {
                Text("Pick a machine or an image in the list.", bundle: #bundle)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.canvas)
            .accessibilityIdentifier("machines.noSelection")
        }
    }

    private var newMachineButton: some View {
        Button(String(localized: "New Machine", bundle: #bundle), systemImage: "plus") {
            model.sheet = .newMachine(imageID: nil)
        }
        .help(model.store.canStartAnother ? String(localized: "New Machine (⇧⌘N)", bundle: #bundle)
            : String(localized: "2 virtual machines are already running", bundle: #bundle))
        .disabled(!model.store.canStartAnother)
        .accessibilityIdentifier("machines.new")
    }

    /// The split view's sidebar: shown or folded as the model says, which keeps an iPad's to one side
    /// column at a time.
    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding {
            model.showsSidebar ? .all : .detailOnly
        } set: { visibility in
            model.setSidebarShown(visibility != .detailOnly)
        }
    }
}

extension View {
    /// Names the item shown: the window's subtitle beside the list, the page's title on an iPhone's
    /// page, where Back takes the list's place.
    @ViewBuilder fileprivate func pageName(_ name: String, layout: WindowLayout) -> some View {
        if layout == .phone {
            navigationTitle(Text(verbatim: name))
        } else {
            navigationSubtitle(Text(verbatim: name))
        }
    }
}

/// The sidebar, or an iPhone's first page: the machines, then the images and Add Image.
private struct MachineList: View {
    @Bindable var model: MachinesModel

    var body: some View {
        let machines = model.machines
        let images = model.images
        List(selection: $model.selection) {
            Section {
                if machines.isEmpty {
                    Text("No machines yet.", bundle: #bundle)
                        .foregroundStyle(.textSecondary)
                        .accessibilityIdentifier("machines.noMachines")
                }
                ForEach(machines) { machine in
                    MachineRow(machine: machine)
                        .tag(MachineSelection.machine(machine.id))
                        .accessibilityIdentifier("machines.row.\(machine.id)")
                }
            } header: {
                Text("Machines", bundle: #bundle)
                    .accessibilityAddTraits(.isHeader)
            }
            Section {
                ForEach(images) { image in
                    ImageRow(image: image)
                        .tag(MachineSelection.image(image.id))
                        .accessibilityIdentifier("machines.image.\(image.id)")
                }
                Button(String(localized: "Add Image…", bundle: #bundle), systemImage: "plus.circle") {
                    model.sheet = .addImage
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.accent)
                .accessibilityIdentifier("machines.addImage.button")
            } header: {
                Text("Images", bundle: #bundle)
                    .accessibilityAddTraits(.isHeader)
            }
        }
        .accessibilityIdentifier("machines.list")
    }
}

/// A machine in the list: its name, system and state.
private struct MachineRow: View {
    let machine: VirtualMachine

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: machine.name)
                Text(verbatim: machine.systemVersion)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: machine.system.symbol)
        }
        .accessibilityElement(children: .combine)
        .badge(Text(machine.state.title))
    }
}

/// An image in the list, with its size or its download.
private struct ImageRow: View {
    let image: MachineImage

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: image.name)
                switch image.state {
                case .ready:
                    Text(image.formattedSize())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .downloading(let progress):
                    ProgressView(value: progress)
                        .controlSize(.mini)
                        .accessibilityLabel(
                            Text("Downloading, \(progress, format: .percent.precision(.fractionLength(0)))", bundle: #bundle)
                        )
                case .installing(let progress):
                    ProgressView(value: progress)
                        .controlSize(.mini)
                        .accessibilityLabel(
                            Text("Installing, \(progress, format: .percent.precision(.fractionLength(0)))", bundle: #bundle)
                        )
                case .needsSetup:
                    Text(image.setup == nil ? String(localized: "Needs setup", bundle: #bundle) : String(localized: "Setting up", bundle: #bundle))
                        .font(.caption)
                        .foregroundStyle(.warning)
                case .failed:
                    Text("Failed", bundle: #bundle, comment: "A system image's status")
                        .font(.caption)
                        .foregroundStyle(.danger)
                }
            }
        } icon: {
            Image(systemName: "opticaldiscdrive")
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("Linux Running", traits: .appChrome, .fixedLayout(width: 1100, height: 760)) {
    MachinesRootView(model: .sample())
}

#Preview("Mac Running, Dark", traits: .appChrome, .fixedLayout(width: 1100, height: 760)) {
    MachinesRootView(model: .sample(focus: "tools-test-mac"))
        .preferredColorScheme(.dark)
}

#Preview("Paused", traits: .appChrome, .fixedLayout(width: 1100, height: 760)) {
    MachinesRootView(model: .sample(focus: "payments-replay"))
}

#Preview("Paused, Dark", traits: .appChrome, .fixedLayout(width: 1100, height: 760)) {
    MachinesRootView(model: .sample(focus: "payments-replay"))
        .preferredColorScheme(.dark)
}

#Preview("Stopped", traits: .appChrome, .fixedLayout(width: 1100, height: 760)) {
    MachinesRootView(model: .sample(focus: "clean-mac"))
}

#Preview("Image Ready", traits: .appChrome, .fixedLayout(width: 1100, height: 760)) {
    MachinesRootView(model: .preview(.image("macos-27-2")))
}

#Preview("Downloading Image", traits: .appChrome, .fixedLayout(width: 1100, height: 760)) {
    MachinesRootView(model: .preview(.image("macos-27-3-beta")))
}

#Preview("Image Needs Setup", traits: .appChrome, .fixedLayout(width: 1100, height: 760)) {
    MachinesRootView(model: .preview(.image("macos-27-1")))
}

#Preview("Setting Up", traits: .appChrome, .fixedLayout(width: 1100, height: 760)) {
    MachinesRootView(model: MachinesModel(store: SampleMachineStore(images: MachineImage.samples.map { image in
        var image = image
        if image.id == "macos-27-1" { image.setup = ImageSetup(state: .running, agentConnected: true, sipOff: true, isRestarting: false) }
        return image
    }), selection: .image("macos-27-1")))
}

#Preview("Image Failed", traits: .appChrome, .fixedLayout(width: 1100, height: 760)) {
    MachinesRootView(model: MachinesModel(store: SampleMachineStore(images: [
        MachineImage(id: "macos-27-0", name: "macOS 27.0", system: .macOS, sizeGB: 0.1, state: .failed("The downloaded file does not match its checksum."))
    ]), selection: .image("macos-27-0")))
}

#Preview("No Selection", traits: .appChrome, .fixedLayout(width: 1100, height: 760)) {
    MachinesRootView(model: .preview(nil))
}

#Preview("Machine Not Found", traits: .appChrome, .fixedLayout(width: 1100, height: 760)) {
    MachinesRootView(model: .sample(focus: "retired-mac"))
}

#Preview("Empty", traits: .appChrome, .fixedLayout(width: 1100, height: 760)) {
    MachinesRootView(model: MachinesModel(focus: nil, store: SampleMachineStore(machines: [], images: [])))
}

#Preview("Wide", traits: .appChrome, .fixedLayout(width: 1900, height: 1150)) {
    MachinesRootView(model: .preview(.image("macos-27-3-beta")))
}

#Preview("iPad", traits: .padLayout, .fixedLayout(width: 760, height: 760)) {
    MachinesRootView(model: .sample())
}

#Preview("iPad, Dark", traits: .padLayout, .fixedLayout(width: 760, height: 760)) {
    MachinesRootView(model: .sample(focus: "tools-test-mac"))
        .preferredColorScheme(.dark)
}

#Preview("iPhone List", traits: .phoneLayout, .fixedLayout(width: 420, height: 800)) {
    MachinesRootView(model: .sample())
}

#Preview("iPhone Machine", traits: .phoneLayout, .fixedLayout(width: 420, height: 800)) {
    MachinesRootView(model: .sample(focus: "orders-sandbox"))
}

#Preview("iPhone Image", traits: .phoneLayout, .fixedLayout(width: 420, height: 800)) {
    MachinesRootView(model: .preview(.image("macos-27-3-beta"), opensSelection: true))
}

#Preview("Largest Text", traits: .largestText, .fixedLayout(width: 1100, height: 760)) {
    MachinesRootView(model: .sample(focus: "orders-sandbox"))
}

#Preview("Largest Text, Image", traits: .largestText, .fixedLayout(width: 1100, height: 760)) {
    MachinesRootView(model: .preview(.image("macos-27-3-beta")))
}
