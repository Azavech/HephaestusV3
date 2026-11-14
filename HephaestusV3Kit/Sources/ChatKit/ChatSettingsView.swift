import AZDesign
import SwiftUI
import ToolsFoundation

/// The chat's pane of the Settings window: the panel switch, what Claude may do, and what replies.
public struct ChatSettingsView: View {
    @AppStorage(ChatPreferences.showsPanelKey) private var showsPanel = true
    @AppStorage(ChatPreferences.ticketChangesKey) private var ticketChanges = ChangePermission.askFirst
    @AppStorage(ChatPreferences.buildStartsKey) private var buildStarts = ChangePermission.never

    public init() {}

    public var body: some View {
        Form {
            Section {
                Toggle(String(localized: "Show the chat panel in tool windows", bundle: #bundle), isOn: $showsPanel)
                    .accessibilityIdentifier("settings.chat.showsPanel")
            } footer: {
                Text("Off, tool windows have no Chat button and no panel. The Chat window stays in the Window menu.", bundle: #bundle)
                    .font(.caption)
                    .foregroundStyle(.textSecondary)
            }
            ChatPermissionsSection(ticketChanges: $ticketChanges, buildStarts: $buildStarts, identifier: "settings.chat.permissions")
            Section {
                ModelRow(identifier: "settings.chat.model")
            } header: {
                Text("Replies", bundle: #bundle, comment: "A section: what answers the user's messages")
                    .accessibilityAddTraits(.isHeader)
            }
        }
        .formStyle(.grouped)
    }
}

/// What Claude may change without asking: the same settings in the Settings window and in the Chat
/// window's inspector. `identifier` qualifies its controls' identifiers: `<identifier>.tickets`.
struct ChatPermissionsSection: View {
    @Binding var ticketChanges: ChangePermission
    @Binding var buildStarts: ChangePermission
    let identifier: String

    var body: some View {
        Section {
            LabeledContent {
                Text(ChangePermission.always.title)
                    .foregroundStyle(.textSecondary)
            } label: {
                Text("Read tickets, services, contracts and builds", bundle: #bundle)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("\(identifier).reads")
            Picker(String(localized: "Change tickets", bundle: #bundle), selection: $ticketChanges) {
                ForEach(ChangePermission.allCases) { permission in
                    Text(permission.title).tag(permission)
                }
            }
            .accessibilityIdentifier("\(identifier).tickets")
            Picker(String(localized: "Start builds", bundle: #bundle), selection: $buildStarts) {
                ForEach([ChangePermission.never, .askFirst]) { permission in
                    Text(permission.title).tag(permission)
                }
            }
            .accessibilityIdentifier("\(identifier).builds")
        } header: {
            Text("Claude Can", bundle: #bundle, comment: "A section: what Claude may do")
                .accessibilityAddTraits(.isHeader)
        } footer: {
            Text("Claude acts through each tool, as you would. Nothing it reads or changes goes around them.", bundle: #bundle)
                .font(.caption)
                .foregroundStyle(.textSecondary)
        }
    }
}

/// The model that replies: none yet.
struct ModelRow: View {
    let identifier: String

    var body: some View {
        LabeledContent(String(localized: "Model", bundle: #bundle), value: String(localized: "None connected", bundle: #bundle, comment: "No model replies yet"))
            .accessibilityIdentifier(identifier)
    }
}

#Preview("Settings", traits: .appChrome, .fixedLayout(width: 520, height: 440)) {
    ChatSettingsView()
}

#Preview("Settings, Dark", traits: .appChrome, .fixedLayout(width: 520, height: 440)) {
    ChatSettingsView()
        .preferredColorScheme(.dark)
}

#Preview("Settings, Largest Text", traits: .largestText, .fixedLayout(width: 520, height: 440)) {
    ChatSettingsView()
}
