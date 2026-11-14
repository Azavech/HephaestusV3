import AZDesign
import AZDesignCode
import MachineData
import SwiftUI
import ToolsFoundation

/// The buttons at the bottom of a sheet: Cancel, and the sheet's action, which is the default button.
private struct SheetButtons: View {
    let action: String
    let identifier: String
    let enabled: Bool
    let working: Bool
    let perform: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack {
            if working {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Button(String(localized: "Cancel", bundle: #bundle)) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("\(identifier).cancel")
            Button(action, action: perform)
                .keyboardShortcut(.defaultAction)
                .disabled(!enabled || working)
                .accessibilityIdentifier("\(identifier).confirm")
        }
        .padding(16)
    }
}

/// A sheet's failure, under its fields.
private struct SheetError: View {
    let message: String?

    var body: some View {
        if let message {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.danger)
                .padding(.horizontal, 20)
                .accessibilityIdentifier("machines.sheet.error")
        }
    }
}

/// The cores, memory and disk fields of New Machine and Edit, with their ranges.
private struct SizeFields: View {
    @Binding var cores: Int
    @Binding var memoryGB: Int
    @Binding var diskGB: Int
    let minimumDiskGB: Int

    var body: some View {
        Stepper(value: $cores, in: MachineDefaults.coresRange) {
            LabeledContent(String(localized: "Cores", bundle: #bundle)) { Text(cores, format: .number) }
        }
        .accessibilityIdentifier("machines.sheet.cores")
        Stepper(value: $memoryGB, in: MachineDefaults.memoryRange) {
            LabeledContent(String(localized: "Memory", bundle: #bundle)) { Text(StorageSize.formatted(gigabytes: Double(memoryGB))) }
        }
        .accessibilityIdentifier("machines.sheet.memory")
        Stepper(value: $diskGB, in: max(minimumDiskGB, MachineDefaults.diskRange.lowerBound)...MachineDefaults.diskRange.upperBound, step: 8) {
            LabeledContent(String(localized: "Disk", bundle: #bundle)) { Text(StorageSize.formatted(gigabytes: Double(diskGB))) }
        }
        .accessibilityIdentifier("machines.sheet.disk")
    }
}

/// New Machine: a name, a Ready image, cores, memory and disk; Create makes the machine and starts it.
struct NewMachineSheet: View {
    let model: MachinesModel
    @State private var name = ""
    @State private var imageID: MachineImage.ID?
    @State private var cores: Int
    @State private var memoryGB: Int
    @State private var diskGB: Int
    @State private var working = false
    @State private var error: String?

    @Environment(\.dismiss) private var dismiss

    init(model: MachinesModel, imageID: MachineImage.ID?) {
        self.model = model
        let ready = model.images.filter { $0.state == .ready }
        let chosen = ready.first { $0.id == imageID } ?? ready.first
        _imageID = State(initialValue: chosen?.id)
        _name = State(initialValue: chosen?.name ?? "")
        let defaults = model.store.defaults
        _cores = State(initialValue: defaults.cores)
        _memoryGB = State(initialValue: defaults.memoryGB)
        _diskGB = State(initialValue: max(defaults.diskGB, chosen.map { model.store.minimumDiskGB(ofImage: $0.id) } ?? 0))
    }

    private var readyImages: [MachineImage] { model.images.filter { $0.state == .ready } }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField(String(localized: "Name", bundle: #bundle), text: $name)
                        .accessibilityIdentifier("machines.newMachine.name")
                    Picker(String(localized: "Image", bundle: #bundle), selection: $imageID) {
                        ForEach(readyImages) { image in
                            Text(verbatim: image.name).tag(Optional(image.id))
                        }
                    }
                    .accessibilityIdentifier("machines.newMachine.image")
                } footer: {
                    if readyImages.isEmpty {
                        Text("No image is Ready: add an image and finish its setup first.", bundle: #bundle)
                    }
                }
                Section {
                    SizeFields(cores: $cores, memoryGB: $memoryGB, diskGB: $diskGB,
                               minimumDiskGB: imageID.map { model.store.minimumDiskGB(ofImage: $0) } ?? 32)
                } footer: {
                    Text("The disk starts as a clone of the image's and can only grow.", bundle: #bundle)
                }
            }
            .formStyle(.grouped)
            SheetError(message: error)
            SheetButtons(action: String(localized: "Create", bundle: #bundle), identifier: "machines.newMachine",
                         enabled: imageID != nil && !name.trimmingCharacters(in: .whitespaces).isEmpty, working: working, perform: create)
        }
        .frame(minWidth: 420, minHeight: 380)
        .navigationTitle(String(localized: "New Machine", bundle: #bundle))
        .accessibilityIdentifier("machines.newMachine")
    }

    private func create() {
        guard let imageID else { return }
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                let id = try await model.store.createMachine(name: name, imageID: imageID, cores: cores, memoryGB: memoryGB, diskGB: diskGB)
                model.selection = .machine(id)
                dismiss()
            } catch {
                self.error = error.localizedDescription
                // A machine that couldn't start stays, stopped.
                if let made = model.machines.last(where: { $0.name == name.trimmingCharacters(in: .whitespaces) && $0.imageID == imageID }) {
                    model.selection = .machine(made.id)
                }
            }
        }
    }
}

/// Edit: a stopped machine's name, cores, memory and disk; the disk only grows.
struct EditMachineSheet: View {
    let model: MachinesModel
    let machine: VirtualMachine
    @State private var name: String
    @State private var cores: Int
    @State private var memoryGB: Int
    @State private var diskGB: Int
    @State private var error: String?

    @Environment(\.dismiss) private var dismiss

    init(model: MachinesModel, machine: VirtualMachine) {
        self.model = model
        self.machine = machine
        _name = State(initialValue: machine.name)
        _cores = State(initialValue: machine.cores)
        _memoryGB = State(initialValue: machine.memoryGB)
        _diskGB = State(initialValue: machine.diskGB)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField(String(localized: "Name", bundle: #bundle), text: $name)
                        .accessibilityIdentifier("machines.editMachine.name")
                }
                Section {
                    SizeFields(cores: $cores, memoryGB: $memoryGB, diskGB: $diskGB, minimumDiskGB: machine.diskGB)
                } footer: {
                    Text("A larger disk grows the guest's container at the next start.", bundle: #bundle)
                }
            }
            .formStyle(.grouped)
            SheetError(message: error)
            SheetButtons(action: String(localized: "Save", bundle: #bundle), identifier: "machines.editMachine",
                         enabled: !name.trimmingCharacters(in: .whitespaces).isEmpty, working: false) {
                do {
                    try model.store.updateMachine(machine.id, name: name, cores: cores, memoryGB: memoryGB, diskGB: diskGB)
                    dismiss()
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
        .frame(minWidth: 420, minHeight: 320)
        .navigationTitle(String(localized: "Edit Machine", bundle: #bundle))
        .accessibilityIdentifier("machines.editMachine")
    }
}

/// Add Image: the macOS versions ipsw.me lists; Add downloads the chosen one and installs it.
struct AddImageSheet: View {
    let model: MachinesModel
    @State private var versions: [MacOSVersion]?
    @State private var build: String?
    @State private var error: String?
    @State private var working = false

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let versions {
                    Form {
                        Picker(String(localized: "Version", bundle: #bundle), selection: $build) {
                            ForEach(versions) { version in
                                Text(label(version)).tag(Optional(version.build))
                            }
                        }
                        .accessibilityIdentifier("machines.addImage.version")
                        Text("The IPSW is downloaded from Apple, then macOS is installed on a 32 GB disk. You finish its setup in the image's page.", bundle: #bundle)
                            .foregroundStyle(.textSecondary)
                    }
                    .formStyle(.grouped)
                } else if error == nil {
                    ProgressView(String(localized: "Reading the versions from ipsw.me…", bundle: #bundle))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("machines.addImage.loading")
                } else {
                    ContentUnavailableView {
                        Label(String(localized: "No Versions", bundle: #bundle), systemImage: "wifi.exclamationmark")
                    } actions: {
                        Button(String(localized: "Try Again", bundle: #bundle)) { Task { await load() } }
                            .accessibilityIdentifier("machines.addImage.retry")
                    }
                }
            }
            .frame(maxHeight: .infinity)
            SheetError(message: error)
            SheetButtons(action: String(localized: "Add", bundle: #bundle), identifier: "machines.addImage", enabled: build != nil,
                         working: working, perform: add)
        }
        .frame(minWidth: 440, minHeight: 280)
        .navigationTitle(String(localized: "Add Image", bundle: #bundle))
        .accessibilityIdentifier("machines.addImage")
        .task { await load() }
    }

    private func label(_ version: MacOSVersion) -> String {
        let size = version.sizeBytes > 0 ? " · " + StorageSize.formatted(gigabytes: Double(version.sizeBytes) / 1_073_741_824, fractionDigits: 1) : ""
        return "macOS \(version.version) (\(version.build))\(size)"
    }

    private func load() async {
        error = nil
        do {
            let list = try await model.store.versions()
            versions = list
            build = build ?? list.first?.build
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func add() {
        guard let build else { return }
        working = true
        Task {
            defer { working = false }
            do {
                let id = try await model.store.addImage(build: build)
                model.selection = .image(id)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Open Shell: a command run by the guest agent in a login shell, as the account or as root, and its output.
struct ShellSheet: View {
    let model: MachinesModel
    let machine: VirtualMachine
    @State private var command = ""
    @State private var asRoot = false
    @State private var result: ShellResult?
    @State private var error: String?
    @State private var running = false

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField(String(localized: "Command", bundle: #bundle), text: $command)
                    .codeFont(.body)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(run)
                    .accessibilityIdentifier("machines.shell.command")
                Toggle(String(localized: "As root", bundle: #bundle), isOn: $asRoot)
                    .accessibilityIdentifier("machines.shell.root")
                Button(String(localized: "Run", bundle: #bundle), action: run)
                    .keyboardShortcut(.defaultAction)
                    .disabled(command.trimmingCharacters(in: .whitespaces).isEmpty || running)
                    .accessibilityIdentifier("machines.shell.run")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if running {
                        ProgressView().controlSize(.small)
                    }
                    if let result {
                        Text(verbatim: result.stdout + result.stderr)
                            .codeFont(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(status(result))
                            .font(.caption)
                            .foregroundStyle(result.exitStatus == 0 ? Color.textSecondary : Color.danger)
                    }
                    if let error {
                        Text(error).foregroundStyle(.danger)
                    }
                }
                .padding(10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.surfaceSunken, in: .rect(cornerRadius: 8))
            .accessibilityIdentifier("machines.shell.output")
            HStack {
                Text("Runs /bin/zsh -lc in the account's home folder, with a timeout of 60 seconds.", bundle: #bundle)
                    .font(.caption)
                    .foregroundStyle(.textSecondary)
                Spacer()
                Button(String(localized: "Done", bundle: #bundle)) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("machines.shell.done")
            }
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 380)
        .navigationTitle(String(localized: "Shell of \(machine.name)", bundle: #bundle))
        .accessibilityIdentifier("machines.shell")
    }

    private func status(_ result: ShellResult) -> String {
        var text = result.timedOut ? String(localized: "Timed out", bundle: #bundle)
            : String(localized: "Exit status \(result.exitStatus)", bundle: #bundle)
        if result.truncated { text += " · " + String(localized: "output cut at 1 MB", bundle: #bundle) }
        return text
    }

    private func run() {
        let command = command.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty, !running else { return }
        running = true
        error = nil
        Task {
            defer { running = false }
            do {
                result = try await model.store.shell(machine.id, command: command, asRoot: asRoot)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
