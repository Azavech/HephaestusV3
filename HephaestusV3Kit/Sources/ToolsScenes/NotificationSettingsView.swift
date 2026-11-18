import AZDesign
import FileStorage
import SwiftUI

/// Settings ▸ Notifications on the app's data.
struct NotificationSettingsPane: View {
    let appData: AppData

    var body: some View {
        NotificationSettingsView(choices: appData.notificationChoices) { choices throws(StorageError) in
            try appData.setNotificationChoices(choices)
        }
    }
}

/// Settings ▸ Notifications: which chat events become notifications, and their line written by Claude
/// (docs/ui/navigation.md › Settings ▸ Notifications).
struct NotificationSettingsView: View {
    let choices: NotificationChoices
    let change: (NotificationChoices) throws(StorageError) -> Void

    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Toggle(String(localized: "Notify when a chat needs you", bundle: #bundle), isOn: binding(\.needsYou))
                    .accessibilityIdentifier("settings.notifications.needsYou")
                Toggle(String(localized: "Notify when Claude finishes replying", bundle: #bundle), isOn: binding(\.finished))
                    .accessibilityIdentifier("settings.notifications.finished")
                Toggle(String(localized: "AI-generated summary", bundle: #bundle), isOn: binding(\.aiSummary))
                    .accessibilityIdentifier("settings.notifications.aiSummary")
                if let message {
                    Text(verbatim: message)
                        .font(.callout)
                        .foregroundStyle(.danger)
                        .accessibilityIdentifier("settings.notifications.message")
                }
            } header: {
                Text("Chats", bundle: #bundle, comment: "Settings ▸ Notifications, the section of the chats' notifications")
            } footer: {
                Text("A chat needs you when Claude asks for a permission or asks you questions. With the summary on, the internal skill notification-summary writes each notification's line; off, the line is the first line of Claude's reply. The Dock's badge counts the chats waiting for you either way.", bundle: #bundle)
                    .font(.callout)
                    .foregroundStyle(.textSecondary)
            }
        }
        .formStyle(.grouped)
    }

    private func binding(_ key: WritableKeyPath<NotificationChoices, Bool>) -> Binding<Bool> {
        Binding {
            choices[keyPath: key]
        } set: { value in
            guard value != choices[keyPath: key] else { return }
            var changed = choices
            changed[keyPath: key] = value
            do throws(StorageError) {
                try change(changed)
                message = nil
            } catch {
                message = error.description
            }
        }
    }
}

#Preview("All On", traits: .fixedLayout(width: 520, height: 440)) {
    NotificationSettingsView(choices: NotificationChoices()) { _ in }
}

#Preview("Summary Off, Dark", traits: .fixedLayout(width: 520, height: 440)) {
    NotificationSettingsView(choices: NotificationChoices(aiSummary: false)) { _ in }
        .preferredColorScheme(.dark)
}

#Preview("Not Stored", traits: .fixedLayout(width: 520, height: 440)) {
    NotificationSettingsView(choices: NotificationChoices()) { _ throws(StorageError) in
        throw .writeFailed(path: "~/Library/Application Support/HephaestusV3/settings.yml", reason: "Permission denied")
    }
}
