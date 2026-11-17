import AZDesign
import FileStorage
import ProjectData
import SwiftUI

/// Settings ▸ General on the app's data.
struct GeneralSettingsPane: View {
    let appData: AppData

    var body: some View {
        GeneralSettingsView(opensWindowsAsTabs: appData.opensWindowsAsTabs) { value throws(StorageError) in
            try appData.setOpensWindowsAsTabs(value)
        }
    }
}

/// Settings ▸ General: how the windows the app opens appear (docs/ui/navigation.md › Settings ▸ General).
struct GeneralSettingsView: View {
    let opensWindowsAsTabs: Bool
    let change: (Bool) throws(StorageError) -> Void

    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Picker(String(localized: "Open new windows", bundle: #bundle), selection: selection) {
                    Text("As tabs of the front window", bundle: #bundle)
                        .tag(true)
                        .accessibilityIdentifier("settings.general.newWindows.tabs")
                    Text("As separate windows", bundle: #bundle)
                        .tag(false)
                        .accessibilityIdentifier("settings.general.newWindows.windows")
                }
                .pickerStyle(.radioGroup)
                .accessibilityIdentifier("settings.general.newWindows")
                if let message {
                    Text(verbatim: message)
                        .font(.callout)
                        .foregroundStyle(.danger)
                        .accessibilityIdentifier("settings.general.message")
                }
            } header: {
                Text("Windows", bundle: #bundle)
            } footer: {
                Text("Applies to the windows Hephaestus opens: a tool, a project, its settings. Windows macOS reopens at launch keep their places, and Window ▸ Merge All Windows and Move Tab to New Window work either way.", bundle: #bundle)
                    .font(.callout)
                    .foregroundStyle(.textSecondary)
            }
        }
        .formStyle(.grouped)
    }

    private var selection: Binding<Bool> {
        Binding {
            opensWindowsAsTabs
        } set: { value in
            guard value != opensWindowsAsTabs else { return }
            do throws(StorageError) {
                try change(value)
                message = nil
            } catch {
                message = error.description
            }
        }
    }
}

#Preview("Tabs", traits: .fixedLayout(width: 520, height: 440)) {
    GeneralSettingsView(opensWindowsAsTabs: true) { _ in }
}

#Preview("Separate Windows, Dark", traits: .fixedLayout(width: 520, height: 440)) {
    GeneralSettingsView(opensWindowsAsTabs: false) { _ in }
        .preferredColorScheme(.dark)
}

#Preview("Not Stored", traits: .fixedLayout(width: 520, height: 440)) {
    GeneralSettingsView(opensWindowsAsTabs: true) { _ throws(StorageError) in
        throw .writeFailed(path: "~/Library/Application Support/HephaestusV3/settings.yml", reason: "Permission denied")
    }
}
