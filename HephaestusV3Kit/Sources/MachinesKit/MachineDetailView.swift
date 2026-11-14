import AZDesign
import AZDesignCode
import SwiftUI
import ToolsFoundation

/// A machine: its screen, as large as the window allows, its actions in the toolbar, and what it runs
/// on in the inspector: beside the screen, or as a sheet over an iPhone's page.
struct MachineDetail: View {
    let machine: VirtualMachine
    @Bindable var model: MachinesModel

    var body: some View {
        Group {
            if model.layout == .phone {
                MachineScreen(machine: machine)
                    .sheet(isPresented: $model.showsInspectorSheet) {
                        inspectorSheet
                    }
            } else {
                MachineScreen(machine: machine)
                    .inspector(isPresented: inspectorShown) {
                        MachineInfo(machine: machine)
                            .inspectorColumnWidth(min: 260, ideal: 300, max: 400)
                    }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if machine.state.isRunning {
                    Button(String(localized: "Pause", bundle: #bundle), systemImage: "pause.fill") {}
                        .help(String(localized: "Pause", bundle: #bundle))
                        .accessibilityIdentifier("machines.pause")
                    Button(String(localized: "Stop", bundle: #bundle), systemImage: "stop.fill") {}
                        .help(String(localized: "Stop", bundle: #bundle))
                        .accessibilityIdentifier("machines.stop")
                } else if let start = machine.state.startAction {
                    Button(start.title, systemImage: "play.fill") {}
                        .help(start.title)
                        .accessibilityIdentifier("machines.start")
                }
                // An iPhone's toolbar has room for the state's buttons only: the rarer ones go in a menu.
                if model.layout == .phone {
                    Menu(String(localized: "More Actions", bundle: #bundle), systemImage: "ellipsis.circle") {
                        snapshotButton
                        shellButton
                    }
                    .help(String(localized: "More Actions", bundle: #bundle))
                    .accessibilityIdentifier("machines.more")
                } else {
                    snapshotButton
                    shellButton
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    // The inspector slides in or out, and an iPad's sidebar with it (a fade with
                    // Reduce Motion).
                    withMotion(.panel) {
                        model.toggleInspector()
                    }
                } label: {
                    Label(String(localized: "Inspector", bundle: #bundle), systemImage: "sidebar.right")
                }
                .help(
                    model.isInspectorShown
                        ? String(localized: "Hide Inspector", bundle: #bundle)
                        : String(localized: "Show Inspector", bundle: #bundle)
                )
                .accessibilityIdentifier("machines.inspectorToggle")
            }
        }
    }

    private var snapshotButton: some View {
        Button(String(localized: "Take Snapshot", bundle: #bundle), systemImage: "camera.on.rectangle") {}
            .help(String(localized: "Take Snapshot", bundle: #bundle))
            .disabled(!machine.state.allowsSnapshot)
            .accessibilityIdentifier("machines.snapshot")
    }

    private var shellButton: some View {
        Button(String(localized: "Open Shell", bundle: #bundle), systemImage: "terminal") {}
            .help(String(localized: "Open Shell", bundle: #bundle))
            .disabled(!machine.state.allowsShell)
            .accessibilityIdentifier("machines.shell")
    }

    /// The inspector beside the screen, shown and hidden through the model, which folds an iPad's
    /// sidebar while it shows.
    private var inspectorShown: Binding<Bool> {
        Binding {
            model.showsInspector
        } set: { shown in
            model.setInspectorShown(shown)
        }
    }

    /// An iPhone's inspector: the same details, over the page, with Done.
    private var inspectorSheet: some View {
        VStack(spacing: 0) {
            MachineInfo(machine: machine)
            HStack {
                Spacer()
                Button(String(localized: "Done", bundle: #bundle, comment: "Closes a virtual machine's details")) {
                    model.showsInspectorSheet = false
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("machines.info.done")
            }
            .padding(12)
        }
        .frame(minWidth: 360, minHeight: 480)
    }
}

/// What a machine runs on, the project it tests, and its snapshots.
private struct MachineInfo: View {
    let machine: VirtualMachine

    @Environment(\.openRoute) private var openRoute

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(machine.state.title, systemImage: "circle.fill")
                        .labelStyle(.badge(machine.state.color))
                        .accessibilityIdentifier("machines.info.state")
                    Text(verbatim: machine.name)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text(verbatim: machine.systemVersion)
                        .foregroundStyle(.textSecondary)
                }

                // Two by two, or one under the other when the text is too large for two side by side.
                ViewThatFits(in: .horizontal) {
                    Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 14) {
                        GridRow {
                            cores
                            memory
                        }
                        GridRow {
                            disk
                            cpu
                        }
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        cores
                        memory
                        disk
                        cpu
                    }
                }

                VStack(spacing: 0) {
                    LabeledContent(String(localized: "Address", bundle: #bundle)) {
                        if let address = machine.address {
                            Text(verbatim: address)
                                .monospaced()
                                .textSelection(.enabled)
                        } else {
                            Text("None while stopped", bundle: #bundle)
                        }
                    }
                    .labeledContentStyle(.detailRow)
                    .accessibilityIdentifier("machines.info.address")
                    Divider()
                    // The project's name is a link of its own, so the row keeps its parts apart.
                    LabeledContent(String(localized: "Project", bundle: #bundle)) {
                        if let projectID = machine.projectID, let project = Project.sample(projectID) {
                            Button {
                                openRoute(.project(project.id))
                            } label: {
                                Label {
                                    Text(verbatim: project.name)
                                } icon: {
                                    ProjectIcon(project)
                                }
                            }
                            .buttonStyle(.link)
                            .accessibilityIdentifier("machines.detail.project")
                        } else {
                            Text("None", bundle: #bundle, comment: "The project of a virtual machine that tests no project")
                        }
                    }
                    .labeledContentStyle(.detailRow(combinesChildren: false))
                    .accessibilityIdentifier("machines.info.project")
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Snapshots", bundle: #bundle)
                        .font(.headline)
                        .foregroundStyle(.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    if machine.snapshots.isEmpty {
                        Text("No snapshots yet.", bundle: #bundle)
                            .foregroundStyle(.textSecondary)
                            .accessibilityIdentifier("machines.info.noSnapshots")
                    } else {
                        ForEach(machine.snapshots) { snapshot in
                            SnapshotRow(snapshot: snapshot)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("machines.info")
    }

    private var cores: some View {
        Figure(Text(machine.cores, format: .number), caption: Text("Cores", bundle: #bundle))
            .accessibilityIdentifier("machines.info.cores")
    }

    private var memory: some View {
        Figure(Text(StorageSize.formatted(gigabytes: Double(machine.memoryGB))), caption: Text("Memory", bundle: #bundle))
            .accessibilityIdentifier("machines.info.memory")
    }

    private var disk: some View {
        Figure(Text(StorageSize.formatted(gigabytes: Double(machine.diskGB))), caption: Text("Disk", bundle: #bundle))
            .accessibilityIdentifier("machines.info.disk")
    }

    private var cpu: some View {
        Figure(Text(machine.cpuUsage, format: .percent.precision(.fractionLength(0))), caption: Text("CPU", bundle: #bundle))
            .accessibilityIdentifier("machines.info.cpu")
    }
}

/// A snapshot: its name and date, and Restore. Restore goes under the name at the largest text sizes.
private struct SnapshotRow: View {
    let snapshot: MachineSnapshot

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
        layout {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: snapshot.name)
                        .foregroundStyle(.textPrimary)
                    Text(snapshot.date, format: .dateTime.day().month(.abbreviated).hour().minute())
                        .font(.caption)
                        .foregroundStyle(.textSecondary)
                }
            }
            .accessibilityElement(children: .combine)
            if !stacked {
                Spacer()
            }
            Button(String(localized: "Restore", bundle: #bundle, comment: "Restores a virtual machine to this snapshot")) {}
                .controlSize(.small)
                .accessibilityIdentifier("machines.snapshot.\(snapshot.id).restore")
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("machines.snapshot.\(snapshot.id)")
    }
}

/// The machine's screen, filling the window as a virtual machine's display does: the guest takes the
/// window's size. Here a stand-in: a desktop for a Mac, a console for Linux, a placeholder while
/// stopped. The real one is the Virtualization framework's view.
private struct MachineScreen: View {
    let machine: VirtualMachine

    var body: some View {
        ZStack {
            switch machine.state {
            case .stopped:
                Rectangle().fill(.surfaceSunken)
                VStack(spacing: 10) {
                    Image(systemName: "power")
                        .font(.largeTitle)
                        .foregroundStyle(.textSecondary)
                        .accessibilityHidden(true)
                    Text(machine.state.title)
                        .font(.title3)
                        .foregroundStyle(.textSecondary)
                    // Over the machine's screen, so in glass, as the screen's other overlays.
                    Button(MachineStartAction.start.title, systemImage: "play.fill") {}
                        .buttonStyle(.glassProminent)
                        .accessibilityIdentifier("machines.screen.start")
                }
            case .running, .paused:
                switch machine.system {
                case .macOS:
                    DesktopStandIn()
                case .linux:
                    ConsoleStandIn(machineID: machine.id)
                }
                if machine.state == .paused {
                    // A veil in the color of inactive regions: the machine is there, but doesn't run.
                    Rectangle()
                        .fill(Color.surfaceSunken.opacity(0.6))
                        .accessibilityHidden(true)
                    Label(machine.state.title, systemImage: "pause.fill")
                        .font(.title3)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .glassEffect()
                        .accessibilityIdentifier("machines.screen.paused")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Screen of \(machine.name)", bundle: #bundle))
        .accessibilityIdentifier("machines.screen")
    }
}

/// A Mac's desktop, drawn as a stand-in: a menu bar strip and a dock. Its words are part of the
/// picture, shown as they are, and hidden from VoiceOver with the rest of it.
private struct DesktopStandIn: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [.accent, .accentSecondary, .info], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    Image(systemName: "apple.logo")
                    Text(verbatim: "Finder").fontWeight(.semibold)
                    Text(verbatim: "File")
                    Text(verbatim: "Edit")
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(.regularMaterial)
                Spacer()
                HStack(spacing: 18) {
                    ForEach(["folder", "safari", "hammer", "terminal", "gearshape"], id: \.self) { symbol in
                        Image(systemName: symbol)
                    }
                }
                .font(.title2)
                .foregroundStyle(.textPrimary)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .glassEffect()
                .padding(.bottom, 10)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A Linux console, drawn as a stand-in: sample shell output, shown as it is, in the code font.
private struct ConsoleStandIn: View {
    let machineID: String

    var body: some View {
        ZStack {
            Rectangle().fill(.surfaceSunken)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: "ubuntu@\(machineID):~$ cd orders && git pull")
                Text(verbatim: "Already up to date.")
                Text(verbatim: "ubuntu@\(machineID):~/orders$ make migrate")
                Text(verbatim: "migrate up: 0014_orders_customer_index.sql (4m 02s)")
                Text(verbatim: "ubuntu@\(machineID):~/orders$ go test ./...")
                Text(verbatim: "ok   orders/api       2.481s")
                Text(verbatim: "ok   orders/store     0.912s")
                Text(verbatim: "ok   orders/events    0.307s")
                Text(verbatim: "ubuntu@\(machineID):~/orders$ ▌")
            }
            .codeFont(.callout)
            .foregroundStyle(.textPrimary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(16)
        }
        .accessibilityHidden(true)
    }
}
