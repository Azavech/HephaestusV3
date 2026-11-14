import AZDesign
import MachineData
import SwiftUI
import ToolsFoundation

/// Settings ▸ Virtual Machines: the cores, memory and disk new machines start with, which the install and the
/// setup of an image use too (`defaultVMCores`, `defaultVMMemoryGB`, `defaultVMDiskGB`).
public struct MachineSettingsView: View {
    private let store: any MachineStore
    @State private var cores: Int
    @State private var memoryGB: Int
    @State private var diskGB: Int
    @State private var error: String?

    public init(store: LiveMachineStore) {
        self.init(anyStore: store)
    }

    init(anyStore store: any MachineStore) {
        self.store = store
        _cores = State(initialValue: store.defaults.cores)
        _memoryGB = State(initialValue: store.defaults.memoryGB)
        _diskGB = State(initialValue: store.defaults.diskGB)
    }

    public var body: some View {
        Form {
            Section {
                Stepper(value: $cores, in: MachineDefaults.coresRange) {
                    LabeledContent(String(localized: "Default cores", bundle: #bundle)) { Text(cores, format: .number) }
                }
                .accessibilityIdentifier("settings.machines.cores")
                Stepper(value: $memoryGB, in: MachineDefaults.memoryRange) {
                    LabeledContent(String(localized: "Default memory", bundle: #bundle)) { Text(StorageSize.formatted(gigabytes: Double(memoryGB))) }
                }
                .accessibilityIdentifier("settings.machines.memory")
                Stepper(value: $diskGB, in: MachineDefaults.diskRange, step: 8) {
                    LabeledContent(String(localized: "Default disk", bundle: #bundle)) { Text(StorageSize.formatted(gigabytes: Double(diskGB))) }
                }
                .accessibilityIdentifier("settings.machines.disk")
            } header: {
                Text("New Machines", bundle: #bundle)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("New Machine starts with these values. An image's install and setup run with the cores and memory.", bundle: #bundle)
                    if let error {
                        Text(error).foregroundStyle(.danger)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: [cores, memoryGB, diskGB]) {
            do {
                try store.setDefaults(MachineDefaults(cores: cores, memoryGB: memoryGB, diskGB: diskGB))
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
        .accessibilityIdentifier("settings.machines")
    }
}

#Preview("Defaults", traits: .fixedLayout(width: 520, height: 440)) {
    MachineSettingsView(anyStore: SampleMachineStore())
}
