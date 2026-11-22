import AppKit
import AZDesign
import AZDesignCode
import MachineData
import SwiftUI
import ToolsFoundation

/// An image: its system, version, size and status, then what it is waiting for: its download or install, its setup,
/// or a button to make a machine from it; its guest account; Delete. While its setup machine runs, the setup view
/// takes the page's place. The page takes the whole detail area: its rows and bars span its width.
struct ImageDetail: View {
    let image: MachineImage
    let model: MachinesModel

    var body: some View {
        if image.setup != nil {
            ImageSetupView(image: image, model: model)
        } else {
            page
        }
    }

    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    Image(systemName: image.system.symbol)
                        .font(.largeTitle)
                        .foregroundStyle(.accent)
                        .accessibilityHidden(true)
                    Text(verbatim: image.name)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                }

                VStack(spacing: 0) {
                    LabeledContent(String(localized: "System", bundle: #bundle)) {
                        Text(verbatim: [image.system.name, image.build.map { "(\($0))" }].compactMap { $0 }.joined(separator: " "))
                    }
                    .accessibilityIdentifier("machines.imageDetail.system")
                    Divider()
                    LabeledContent(String(localized: "Size", bundle: #bundle)) {
                        Text(image.formattedSize())
                    }
                    .accessibilityIdentifier("machines.imageDetail.size")
                    Divider()
                    LabeledContent(String(localized: "Status", bundle: #bundle)) {
                        Text(status)
                    }
                    .accessibilityIdentifier("machines.imageDetail.status")
                }
                .labeledContentStyle(.detailRow)

                stateContent

                GuestAccountSection(image: image, model: model)

                Button(String(localized: "Delete Image…", bundle: #bundle), systemImage: "trash", role: .destructive) {
                    model.pendingDeletion = .image(image.id)
                }
                .disabled(model.isBusy(image.id))
                .accessibilityIdentifier("machines.imageDetail.delete")
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.canvas)
        .accessibilityIdentifier("machines.imageDetail")
    }

    @ViewBuilder private var stateContent: some View {
        switch image.state {
        case .ready:
            // On the page's own background, not over other content: no glass.
            Button(String(localized: "New Machine from This Image", bundle: #bundle), systemImage: "plus") {
                model.sheet = .newMachine(imageID: image.id)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.store.canStartAnother)
            .accessibilityIdentifier("machines.imageDetail.newMachine")
        case .downloading(let progress), .installing(let progress):
            VStack(alignment: .leading, spacing: 12) {
                ProgressView(value: progress) {
                    Text(image.downloadedSize() ?? phase)
                } currentValueLabel: {
                    Text(progress, format: .percent.precision(.fractionLength(0)))
                }
                .accessibilityIdentifier("machines.imageDetail.progress")
                Button(String(localized: "Cancel Download", bundle: #bundle)) {
                    model.pendingDeletion = .image(image.id)
                }
                .accessibilityIdentifier("machines.imageDetail.cancelDownload")
            }
        case .needsSetup:
            VStack(alignment: .leading, spacing: 12) {
                Text("macOS is installed. Set it up once: complete Setup Assistant, turn off SIP and install the guest agent. Machines then start from it.", bundle: #bundle)
                    .foregroundStyle(.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(String(localized: "Set Up…", bundle: #bundle), systemImage: "wrench.and.screwdriver") {
                    // An account typed but not saved is saved first, so Type Password works in the setup.
                    if model.accountChanged(image.id) { try? model.saveAccount(of: image.id) }
                    model.perform(image.id, String(localized: "Set Up failed", bundle: #bundle)) { [store = model.store, id = image.id] in
                        try await store.startSetup(id)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy(image.id) || !model.store.canStartAnother)
                .accessibilityIdentifier("machines.imageDetail.setUp")
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.danger)
                .accessibilityIdentifier("machines.imageDetail.failure")
        }
    }

    private var phase: String {
        if case .installing = image.state { return String(localized: "Installing macOS", bundle: #bundle) }
        return String(localized: "Downloading", bundle: #bundle)
    }

    private var status: String {
        switch image.state {
        case .ready: String(localized: "Ready", bundle: #bundle, comment: "A system image's status: new machines can start from it")
        case .downloading: String(localized: "Downloading", bundle: #bundle, comment: "A system image's status")
        case .installing: String(localized: "Installing", bundle: #bundle, comment: "A system image's status")
        case .needsSetup: String(localized: "Needs setup", bundle: #bundle, comment: "A system image's status: installed, its setup isn't finished")
        case .failed: String(localized: "Failed", bundle: #bundle, comment: "A system image's status")
        }
    }
}

/// The guest account of an image's machines: the user name and password created in Setup Assistant, kept in
/// `image.yml` for Type Password.
private struct GuestAccountSection: View {
    let image: MachineImage
    let model: MachinesModel
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Guest Account", bundle: #bundle)
                .font(.headline)
                .foregroundStyle(.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text("The account created in Setup Assistant. Type Password types this password into the image's machines.", bundle: #bundle)
                .font(.callout)
                .foregroundStyle(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField(String(localized: "User name", bundle: #bundle), text: Binding {
                model.account(of: image.id).userName
            } set: { model.editAccount(of: image.id, userName: $0) })
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("machines.imageDetail.userName")
            SecureField(String(localized: "Password", bundle: #bundle), text: Binding {
                model.account(of: image.id).password
            } set: { model.editAccount(of: image.id, password: $0) })
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("machines.imageDetail.password")
            HStack {
                if let error {
                    Text(error).foregroundStyle(.danger)
                }
                Spacer()
                Button(String(localized: "Save Account", bundle: #bundle)) {
                    do {
                        try model.saveAccount(of: image.id)
                        error = nil
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .disabled(!model.accountChanged(image.id))
                .accessibilityIdentifier("machines.imageDetail.saveAccount")
            }
        }
        .onChange(of: image.id) {
            error = nil
        }
    }
}

/// An image's setup: its machine's screen and, beside it, the three steps, Type Password, the agent's status,
/// Finish Setup and Stop (docs/ui/virtual-machines.md › Setup).
private struct ImageSetupView: View {
    let image: MachineImage
    let model: MachinesModel
    @State private var keyboard = GuestKeyboard()
    @State private var copied = false

    private var setup: ImageSetup { image.setup ?? ImageSetup(state: .stopped, agentConnected: false, sipOff: false, isRestarting: false) }

    var body: some View {
        let layout = model.layout == .phone ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        layout {
            screen
            Divider()
            ScrollView {
                steps
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: model.layout == .phone ? nil : 300)
            .frame(maxHeight: model.layout == .phone ? 360 : .infinity)
            .background(.canvas)
        }
        .accessibilityIdentifier("machines.setup")
    }

    @ViewBuilder private var screen: some View {
        ZStack {
            Rectangle().fill(.black)
            if let machine = model.store.screen(image.id) {
                VirtualMachineScreen(machine: machine, keyboard: keyboard)
            } else {
                Text("The setup machine's screen shows here.", bundle: #bundle)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel(Text("Screen of \(image.name)", bundle: #bundle))
        .accessibilityIdentifier("machines.setup.screen")
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set Up \(image.name)", bundle: #bundle)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            step(1, Text("Complete Setup Assistant: create an account and turn on automatic login.", bundle: #bundle))
            VStack(alignment: .leading, spacing: 8) {
                step(2, Text("Turn off SIP:", bundle: #bundle))
                Button(String(localized: "Restart in Recovery", bundle: #bundle)) {
                    model.perform(image.id, String(localized: "Restart in Recovery failed", bundle: #bundle)) { [store = model.store, id = image.id] in
                        try await store.restartInRecovery(id)
                    }
                }
                .disabled(setup.isRestarting || setup.state != .running)
                .accessibilityIdentifier("machines.setup.recovery")
                Text("In Recovery, open Utilities ▸ Terminal, run csrutil disable, then restart.", bundle: #bundle)
                    .font(.callout)
                    .foregroundStyle(.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                step(3, Text("Install the agent: in Terminal, run", bundle: #bundle))
                Text(verbatim: GuestTools.installCommand)
                    .codeFont(.callout)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.surfaceSunken, in: .rect(cornerRadius: 6))
                    .accessibilityIdentifier("machines.setup.command")
                Button(copied ? String(localized: "Copied", bundle: #bundle) : String(localized: "Copy", bundle: #bundle)) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(GuestTools.installCommand, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                }
                .accessibilityIdentifier("machines.setup.copy")
                Text("The guest shares no pasteboard with this Mac: type the command there.", bundle: #bundle)
                    .font(.caption)
                    .foregroundStyle(.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TypePasswordButton(keyboard: keyboard, password: model.store.password(ofImage: image.id), enabled: setup.state == .running) { message in
                model.alert = MachineAlert(title: String(localized: "Type Password failed", bundle: #bundle), message: message)
            }
            .accessibilityIdentifier("machines.setup.typePassword")
            Divider()
            Label(statusLine, systemImage: setup.agentConnected ? "checkmark.circle.fill" : "hourglass")
                .foregroundStyle(setup.canFinish ? Color.success : Color.textSecondary)
                .accessibilityIdentifier("machines.setup.status")
            HStack {
                Button(String(localized: "Finish Setup", bundle: #bundle)) {
                    model.perform(image.id, String(localized: "Finish Setup failed", bundle: #bundle)) { [store = model.store, id = image.id] in
                        try await store.finishSetup(id)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!setup.canFinish || model.isBusy(image.id))
                .accessibilityIdentifier("machines.setup.finish")
                Button(String(localized: "Stop", bundle: #bundle)) {
                    Task { await model.store.stopSetup(image.id) }
                }
                .disabled(setup.state == .stopping)
                .accessibilityIdentifier("machines.setup.stop")
            }
        }
    }

    private var statusLine: String {
        if setup.isRestarting { return String(localized: "Restarting in Recovery…", bundle: #bundle) }
        if !setup.agentConnected { return String(localized: "Waiting for the agent…", bundle: #bundle) }
        return setup.sipOff ? String(localized: "Agent connected · SIP off", bundle: #bundle)
            : String(localized: "Agent connected · SIP on", bundle: #bundle)
    }

    private func step(_ number: Int, _ text: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(number, format: .number)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.accent)
            text
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
