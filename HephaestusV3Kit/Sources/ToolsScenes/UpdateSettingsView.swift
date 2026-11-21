import AZDesign
import FileStorage
import SwiftUI
import UpdateData

/// Settings ▸ Updates on the app's Updater.
struct UpdateSettingsPane: View {
    let controller: UpdateController

    var body: some View {
        UpdateSettingsView(
            version: controller.appVersion, repository: controller.repository, autoUpdate: controller.autoUpdate,
            intervalMinutes: controller.intervalMinutes, canCheck: controller.isRunning, updateNowVisible: controller.updateNowVisible,
            statusLine: controller.settingsStatusLine,
            setAutoUpdate: { value throws(StorageError) in try controller.setAutoUpdate(value) },
            setInterval: { value throws(StorageError) in try controller.setIntervalMinutes(value) },
            checkNow: controller.postCheck, updateNow: controller.install)
    }
}

/// Settings ▸ Updates (docs/ui/updates.md › Settings ▸ Updates): V2's tab, its version, its two settings, its
/// repository, Check Now and Update Now, and the status line of the About window.
struct UpdateSettingsView: View {
    let version: AppVersion
    let repository: String
    let autoUpdate: Bool
    let intervalMinutes: Int
    /// Check Now works while the Updater runs.
    let canCheck: Bool
    let updateNowVisible: Bool
    let statusLine: UpdateArea
    let setAutoUpdate: (Bool) throws(StorageError) -> Void
    let setInterval: (Int) throws(StorageError) -> Void
    let checkNow: () -> Void
    let updateNow: () -> Void

    @State private var message: String?

    var body: some View {
        Form {
            Section {
                LabeledContent(String(localized: "Version", bundle: #bundle)) {
                    Text(UpdateTexts.aboutLine(version))
                        .textSelection(.enabled)
                }
                .accessibilityIdentifier("settings.updates.version")
                Toggle(String(localized: "Automatically install updates", bundle: #bundle), isOn: Binding {
                    autoUpdate
                } set: { value in
                    guard value != autoUpdate else { return }
                    apply { () throws(StorageError) in try setAutoUpdate(value) }
                })
                .accessibilityIdentifier("settings.updates.autoUpdate")
                Picker(String(localized: "Check for updates", bundle: #bundle), selection: Binding {
                    intervalMinutes
                } set: { value in
                    guard value != intervalMinutes else { return }
                    apply { () throws(StorageError) in try setInterval(value) }
                }) {
                    ForEach(choices, id: \.self) { minutes in
                        Text(Self.intervalLabel(minutes)).tag(minutes)
                    }
                }
                .accessibilityIdentifier("settings.updates.interval")
                LabeledContent(String(localized: "Release repository", bundle: #bundle)) {
                    Text(verbatim: repository)
                        .textSelection(.enabled)
                }
                .accessibilityIdentifier("settings.updates.repository")
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Button(String(localized: "Check Now", bundle: #bundle), action: checkNow)
                            .disabled(!canCheck)
                            .accessibilityIdentifier("settings.updates.checkNow")
                        if updateNowVisible {
                            Button(String(localized: "Update Now", bundle: #bundle), action: updateNow)
                                .accessibilityIdentifier("settings.updates.updateNow")
                        }
                    }
                    UpdateLine(area: statusLine)
                        .font(.callout)
                        .accessibilityIdentifier("settings.updates.status")
                }
                if let message {
                    Text(verbatim: message)
                        .font(.callout)
                        .foregroundStyle(.danger)
                        .accessibilityIdentifier("settings.updates.message")
                }
            } header: {
                Text("Updates", bundle: #bundle, comment: "Settings ▸ Updates, its section")
            } footer: {
                Text("Hephaestus V3 looks for a newer release on GitHub 10 seconds after it opens, then at this interval. With automatic updates, it restarts to install one once no chat is at work or waiting, no virtual machine runs and no draft is unsent; otherwise the status bar offers it.", bundle: #bundle)
                    .font(.callout)
                    .foregroundStyle(.textSecondary)
            }
        }
        .formStyle(.grouped)
    }

    /// The choices, and a stored value that isn't one of them.
    private var choices: [Int] {
        UpdateInterval.choices.contains(intervalMinutes) ? UpdateInterval.choices : (UpdateInterval.choices + [intervalMinutes]).sorted()
    }

    static func intervalLabel(_ minutes: Int) -> String {
        switch minutes {
        case 15: String(localized: "Every 15 minutes", bundle: #bundle)
        case 30: String(localized: "Every 30 minutes", bundle: #bundle)
        case 60: String(localized: "Every hour", bundle: #bundle)
        case 120: String(localized: "Every 2 hours", bundle: #bundle)
        case 360: String(localized: "Every 6 hours", bundle: #bundle)
        case 1440: String(localized: "Every day", bundle: #bundle)
        default: String(localized: "Every \(minutes) minutes", bundle: #bundle, comment: "A check interval stored by hand")
        }
    }

    private func apply(_ change: () throws(StorageError) -> Void) {
        do throws(StorageError) {
            try change()
            message = nil
        } catch {
            message = error.description
        }
    }
}

private func previewSettings(autoUpdate: Bool = true, canCheck: Bool = true, updateNow: Bool = false, line: UpdateArea,
                             failing: Bool = false) -> UpdateSettingsView {
    UpdateSettingsView(version: AppVersion(version: "1.0.43", build: 78), repository: ReleaseFeed.repository, autoUpdate: autoUpdate,
                       intervalMinutes: 30, canCheck: canCheck, updateNowVisible: updateNow, statusLine: line,
                       setAutoUpdate: { _ throws(StorageError) in
                           if failing { throw .writeFailed(path: "~/Library/Application Support/HephaestusV3/settings.yml", reason: "Permission denied") }
                       },
                       setInterval: { _ in }, checkNow: {}, updateNow: {})
}

#Preview("Up to Date", traits: .fixedLayout(width: 520, height: 440)) {
    previewSettings(line: UpdateArea.settingsStatusLine(.init(status: UpdaterStatus(state: .upToDate))))
}

#Preview("Update Ready, Dark", traits: .fixedLayout(width: 520, height: 440)) {
    previewSettings(autoUpdate: false, updateNow: true,
                    line: UpdateArea.settingsStatusLine(.init(status: UpdaterStatus(state: .ready, version: "1.0.44", build: 80))))
        .preferredColorScheme(.dark)
}

#Preview("Repository Private", traits: .fixedLayout(width: 520, height: 440)) {
    previewSettings(line: UpdateArea.settingsStatusLine(.init(status: UpdaterStatus(state: .error, message: UpdaterTexts.repositoryHidden(ReleaseFeed.repository)))))
}

#Preview("Development Build", traits: .fixedLayout(width: 520, height: 440)) {
    previewSettings(canCheck: false, line: UpdateArea.settingsStatusLine(.init(unavailableReason: UpdaterTexts.developmentBuild)))
}
