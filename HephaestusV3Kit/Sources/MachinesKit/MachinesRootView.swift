import AZDesign
import SwiftUI
import ToolsFoundation

/// The Virtual Machines window: the Mac's machines and images. It isn't tied to one project;
/// a machine can name the project it tests.
///
/// It adapts to its width as the tool windows do: a Mac's sidebar, screen and inspector side by side;
/// an iPad's with the inspector folded behind its button; an iPhone's one pane at a time.
public struct MachinesRootView: View {
    /// The window's size, size classes and whether it narrowed from a regular width (AZDesign), which
    /// pick the Mac's, an iPad's or an iPhone's layout.
    @State private var adaptiveWindow = AdaptiveWindowState()
    @State private var model: MachinesModel

    /// No window gets narrower than an iPhone, or lower than the tool windows.
    private static let minimumSize = CGSize(width: 390, height: 420)

    /// The machines, with `focus` (a machine id) selected when the window opens. Routes that arrive
    /// later, while it is open, come as a `FocusRequest` in the environment.
    public init(focus: String? = nil) {
        self.init(model: MachinesModel(focus: focus, store: SampleMachineStore()))
    }

    init(model: MachinesModel) {
        _model = State(initialValue: model)
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
        // File ▸ New Machine… (⇧⌘N), as the toolbar's New Machine. Not wired yet.
        .newItemCommand(String(localized: "New Machine…", bundle: #bundle, comment: "File menu item, ⇧⌘N")) {}
    }

    /// A Mac's sidebar, screen and inspector; an iPad's with one side column at a time.
    private var splitBody: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            MachineList(machines: model.machines, images: model.images, selection: $model.selection)
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
            MachineList(machines: model.machines, images: model.images, selection: $model.selection)
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
            ImageDetail(image: image)
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
        Button(String(localized: "New Machine", bundle: #bundle), systemImage: "plus") {}
            .help(String(localized: "New Machine (⇧⌘N)", bundle: #bundle))
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

/// The sidebar, or an iPhone's first page: the machines, then the images.
private struct MachineList: View {
    let machines: [VirtualMachine]
    let images: [MachineImage]
    @Binding var selection: MachineSelection?

    var body: some View {
        List(selection: $selection) {
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
            if !images.isEmpty {
                Section {
                    ForEach(images) { image in
                        ImageRow(image: image)
                            .tag(MachineSelection.image(image.id))
                            .accessibilityIdentifier("machines.image.\(image.id)")
                    }
                } header: {
                    Text("Images", bundle: #bundle)
                        .accessibilityAddTraits(.isHeader)
                }
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
                }
            }
        } icon: {
            Image(systemName: "opticaldiscdrive")
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("Linux Running", traits: .appChrome, .fixedLayout(width: 1100, height: 760)) {
    MachinesRootView()
}

#Preview("Mac Running, Dark", traits: .appChrome, .fixedLayout(width: 1100, height: 760)) {
    MachinesRootView(focus: "tools-test-mac")
        .preferredColorScheme(.dark)
}

#Preview("Paused", traits: .appChrome, .fixedLayout(width: 1100, height: 760)) {
    MachinesRootView(focus: "payments-replay")
}

#Preview("Paused, Dark", traits: .appChrome, .fixedLayout(width: 1100, height: 760)) {
    MachinesRootView(focus: "payments-replay")
        .preferredColorScheme(.dark)
}

#Preview("Stopped", traits: .appChrome, .fixedLayout(width: 1100, height: 760)) {
    MachinesRootView(focus: "clean-mac")
}

#Preview("Image Ready", traits: .appChrome, .fixedLayout(width: 1100, height: 760)) {
    MachinesRootView(model: .preview(.image("macos-27-2")))
}

#Preview("Downloading Image", traits: .appChrome, .fixedLayout(width: 1100, height: 760)) {
    MachinesRootView(model: .preview(.image("macos-27-3-beta")))
}

#Preview("No Selection", traits: .appChrome, .fixedLayout(width: 1100, height: 760)) {
    MachinesRootView(model: .preview(nil))
}

#Preview("Machine Not Found", traits: .appChrome, .fixedLayout(width: 1100, height: 760)) {
    MachinesRootView(focus: "retired-mac")
}

#Preview("Empty", traits: .appChrome, .fixedLayout(width: 1100, height: 760)) {
    MachinesRootView(model: MachinesModel(focus: nil, store: SampleMachineStore(machines: [], images: [])))
}

#Preview("Wide", traits: .appChrome, .fixedLayout(width: 1900, height: 1150)) {
    MachinesRootView(model: .preview(.image("macos-27-3-beta")))
}

#Preview("iPad", traits: .padLayout, .fixedLayout(width: 760, height: 760)) {
    MachinesRootView()
}

#Preview("iPad, Dark", traits: .padLayout, .fixedLayout(width: 760, height: 760)) {
    MachinesRootView(focus: "tools-test-mac")
        .preferredColorScheme(.dark)
}

#Preview("iPhone List", traits: .phoneLayout, .fixedLayout(width: 420, height: 800)) {
    MachinesRootView()
}

#Preview("iPhone Machine", traits: .phoneLayout, .fixedLayout(width: 420, height: 800)) {
    MachinesRootView(focus: "orders-sandbox")
}

#Preview("iPhone Image", traits: .phoneLayout, .fixedLayout(width: 420, height: 800)) {
    MachinesRootView(model: .preview(.image("macos-27-3-beta"), opensSelection: true))
}

#Preview("Largest Text", traits: .largestText, .fixedLayout(width: 1100, height: 760)) {
    MachinesRootView(focus: "orders-sandbox")
}

#Preview("Largest Text, Image", traits: .largestText, .fixedLayout(width: 1100, height: 760)) {
    MachinesRootView(model: .preview(.image("macos-27-3-beta")))
}
