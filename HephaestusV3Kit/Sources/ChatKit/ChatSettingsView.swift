import AZDesign
import ChatData
import SwiftUI
import ToolsFoundation

/// The chat's pane of the Settings window: the panel switch, the Claude CLI, what Claude may do, and what
/// replies to new chats.
public struct ChatSettingsView: View {
    @AppStorage(ChatPreferences.showsPanelKey) private var showsPanel = true
    @AppStorage(ChatPreferences.ticketChangesKey) private var ticketChanges = ChangePermission.askFirst
    @AppStorage(ChatPreferences.projectChangesKey) private var projectChanges = ChangePermission.askFirst
    @AppStorage(ChatPreferences.buildStartsKey) private var buildStarts = ChangePermission.never
    @Environment(\.chatStore) private var store
    @State private var path = ""
    @State private var failure: String?
    /// The CLI as a preview shows it, without the app's chats.
    private var previewStatus: ClaudeStatus?

    public init() {}

    init(previewStatus: ClaudeStatus) {
        self.previewStatus = previewStatus
    }

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
            if let status = store?.session.status ?? previewStatus {
                cliSection(status)
            }
            ChatPermissionsSection(ticketChanges: $ticketChanges, projectChanges: $projectChanges, buildStarts: $buildStarts,
                                   identifier: "settings.chat.permissions")
            Section {
                if let store {
                    ReplySettingsRows(models: store.session.models, settings: store.session.defaults, identifier: "settings.chat",
                                      isChat: true) { settings in
                        do throws(ChatError) {
                            try store.session.setDefaults(settings)
                        } catch {
                            failure = error.description
                        }
                    }
                } else if previewStatus != nil {
                    ReplySettingsRows(models: ClaudeModel.fallback, settings: ChatSettings(), identifier: "settings.chat", isChat: true) { _ in }
                } else {
                    ModelRow(identifier: "settings.chat.model")
                }
            } header: {
                Text("Replies", bundle: #bundle, comment: "A section: what answers the user's messages")
                    .accessibilityAddTraits(.isHeader)
            } footer: {
                if store != nil || previewStatus != nil {
                    Text("New chats start with these. Each chat keeps its own, in the Chat window's inspector.", bundle: #bundle)
                        .font(.caption)
                        .foregroundStyle(.textSecondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            path = store?.session.claudePath ?? ""
        }
    }

    /// The CLI the chats run: found, or the path the user set, with its version or why it can't run.
    private func cliSection(_ status: ClaudeStatus) -> some View {
        Section {
            LabeledContent(String(localized: "Status", bundle: #bundle, comment: "The Claude CLI's status")) {
                if status.checking {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Looking…", bundle: #bundle, comment: "The app looks for the Claude CLI")
                    }
                } else if let version = status.version {
                    Label {
                        Text("Claude Code \(version)", bundle: #bundle, comment: "The CLI's version, such as 2.1.322")
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.success)
                    }
                } else {
                    Label {
                        Text(verbatim: status.error ?? "")
                            .multilineTextAlignment(.trailing)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.danger)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings.chat.cli.status")
            TextField(String(localized: "Path", bundle: #bundle, comment: "The Claude CLI's path"), text: $path,
                      prompt: Text(verbatim: status.path ?? String(localized: "Found automatically", bundle: #bundle)))
                .font(.body.monospaced())
                .onSubmit(applyPath)
                .accessibilityIdentifier("settings.chat.cli.path")
            HStack {
                if let failure {
                    Text(verbatim: failure)
                        .font(.caption)
                        .foregroundStyle(.danger)
                }
                Spacer()
                Button(String(localized: "Look Again", bundle: #bundle, comment: "Looks for the Claude CLI again"), action: applyPath)
                    .disabled(status.checking)
                    .accessibilityIdentifier("settings.chat.cli.lookAgain")
            }
        } header: {
            Text("Claude CLI", bundle: #bundle)
                .accessibilityAddTraits(.isHeader)
        } footer: {
            Text("Chats run Claude Code from this Mac. Empty, the app finds it in ~/.local/bin, /opt/homebrew/bin, /usr/local/bin, or your shell's PATH.", bundle: #bundle)
                .font(.caption)
                .foregroundStyle(.textSecondary)
        }
    }

    private func applyPath() {
        guard let store else { return }
        do throws(ChatError) {
            try store.session.setClaudePath(path)
            failure = nil
        } catch {
            failure = error.description
        }
    }
}

/// The model and effort of a chat, or of new chats: pop-up buttons over the CLI's models, the effort's
/// over the model's levels. `identifier` qualifies theirs: `<identifier>.model`, `<identifier>.effort`.
struct ReplySettingsRows: View {
    let models: [ClaudeModel]
    let settings: ChatSettings
    let identifier: String
    /// The rows of one chat, as V2's composer menus: its permission mode, Ultracode and context window too.
    var isChat = false
    let set: (ChatSettings) -> Void

    var body: some View {
        Picker(String(localized: "Model", bundle: #bundle), selection: Binding(get: { settings.model }, set: { model in
            var changed = settings
            changed.model = model
            set(changed)
        })) {
            ForEach(models) { model in
                Text(verbatim: model.displayName).tag(model.value)
            }
            if !models.contains(where: { $0.value == settings.model }) {
                Text(verbatim: settings.model).tag(settings.model)
            }
        }
        .accessibilityIdentifier("\(identifier).model")
        if !efforts.isEmpty {
            Picker(String(localized: "Effort", bundle: #bundle, comment: "How hard Claude thinks"), selection: Binding(get: { settings.effort }, set: { effort in
                var changed = settings
                changed.effort = effort
                set(changed)
            })) {
                ForEach(efforts, id: \.self) { effort in
                    Text(Self.title(effort)).tag(effort)
                }
            }
            .accessibilityIdentifier("\(identifier).effort")
        }
        if isChat {
            Picker(String(localized: "Permissions", bundle: #bundle, comment: "A chat's permission mode"), selection: Binding(
                get: { ChatPermissionMode(stored: settings.permissionMode) },
                set: { mode in
                    var changed = settings
                    changed.permissionMode = mode.rawValue
                    set(changed)
                })) {
                ForEach(ChatPermissionMode.allCases, id: \.self) { mode in
                    Text(Self.title(mode)).tag(mode)
                }
            }
            .help(Self.subtitle(ChatPermissionMode(stored: settings.permissionMode)))
            .accessibilityIdentifier("\(identifier).permissionMode")
            Toggle(String(localized: "Ultracode", bundle: #bundle), isOn: Binding(get: { settings.ultracode }, set: { on in
                var changed = settings
                changed.ultracode = on
                set(changed)
            }))
            .help(String(localized: "Standing dynamic-workflow orchestration for this chat, at any effort level.", bundle: #bundle))
            .accessibilityIdentifier("\(identifier).ultracode")
            Picker(String(localized: "Context", bundle: #bundle, comment: "A chat's context window"), selection: Binding(
                get: { ChatContextWindow(stored: settings.contextWindow) },
                set: { window in
                    var changed = settings
                    changed.contextWindow = window.rawValue
                    set(changed)
                })) {
                ForEach(ChatContextWindow.allCases, id: \.self) { window in
                    Text(Self.title(window)).tag(window)
                }
            }
            .accessibilityIdentifier("\(identifier).contextWindow")
        }
    }

    /// V2's labels of the permission modes.
    static func title(_ mode: ChatPermissionMode) -> String {
        switch mode {
        case .manual: String(localized: "Ask Every Time", bundle: #bundle, comment: "A permission mode")
        case .acceptEdits: String(localized: "Accept Edits", bundle: #bundle, comment: "A permission mode")
        case .plan: String(localized: "Plan Only", bundle: #bundle, comment: "A permission mode")
        case .auto: String(localized: "Auto", bundle: #bundle, comment: "A permission mode")
        case .dontAsk: String(localized: "Don't Ask", bundle: #bundle, comment: "A permission mode")
        case .bypassPermissions: String(localized: "Allow All", bundle: #bundle, comment: "A permission mode")
        }
    }

    /// What each mode does, as V2's menu said it.
    static func subtitle(_ mode: ChatPermissionMode) -> String {
        switch mode {
        case .manual: String(localized: "Claude asks before it edits files or runs commands.", bundle: #bundle)
        case .acceptEdits: String(localized: "File edits are accepted; other actions ask.", bundle: #bundle)
        case .plan: String(localized: "Claude plans and changes nothing.", bundle: #bundle)
        case .auto: String(localized: "A classifier approves or denies each request.", bundle: #bundle)
        case .dontAsk: String(localized: "Anything not pre-approved is denied without asking.", bundle: #bundle)
        case .bypassPermissions: String(localized: "Every action runs without asking.", bundle: #bundle)
        }
    }

    static func title(_ window: ChatContextWindow) -> String {
        switch window {
        case .auto: String(localized: "Auto", bundle: #bundle, comment: "The model's own context window")
        case .window200K: String(localized: "200K", bundle: #bundle, comment: "A context window of 200,000 tokens")
        case .window1M: String(localized: "1M", bundle: #bundle, comment: "A context window of a million tokens")
        }
    }

    /// The model's levels; every level for a model the list doesn't have; none for a model without effort.
    private var efforts: [Effort] {
        models.first { $0.value == settings.model }?.efforts ?? Effort.allCases
    }

    static func title(_ effort: Effort) -> String {
        switch effort {
        case .low: String(localized: "Low", bundle: #bundle, comment: "An effort level")
        case .medium: String(localized: "Medium", bundle: #bundle, comment: "An effort level")
        case .high: String(localized: "High", bundle: #bundle, comment: "An effort level")
        case .xhigh: String(localized: "Extra High", bundle: #bundle, comment: "An effort level")
        case .max: String(localized: "Max", bundle: #bundle, comment: "An effort level")
        }
    }
}

/// What Claude may change without asking: the same settings in the Settings window and in the Chat
/// window's inspector. `identifier` qualifies its controls' identifiers: `<identifier>.tickets`.
struct ChatPermissionsSection: View {
    @Binding var ticketChanges: ChangePermission
    @Binding var projectChanges: ChangePermission
    @Binding var buildStarts: ChangePermission
    @AppStorage(ChatPreferences.apiCallsKey) private var apiCalls = ChangePermission.askFirst
    @AppStorage(ChatPreferences.clusterChangesKey) private var clusterChanges = ChangePermission.askFirst
    @AppStorage(ChatPreferences.machineChangesKey) private var machineChanges = ChangePermission.askFirst
    @AppStorage(ChatPreferences.fileEditsKey) private var fileEdits = ChangePermission.askFirst
    let identifier: String

    var body: some View {
        Section {
            LabeledContent {
                Text(ChangePermission.always.title)
                    .foregroundStyle(.textSecondary)
            } label: {
                Text("Read tickets, services, contracts, builds, machines and the project's files", bundle: #bundle)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("\(identifier).reads")
            Picker(String(localized: "Edit the project's files", bundle: #bundle), selection: $fileEdits) {
                ForEach(ChangePermission.allCases) { permission in
                    Text(permission.title).tag(permission)
                }
            }
            .accessibilityIdentifier("\(identifier).files")
            Picker(String(localized: "Change tickets", bundle: #bundle), selection: $ticketChanges) {
                ForEach(ChangePermission.allCases) { permission in
                    Text(permission.title).tag(permission)
                }
            }
            .accessibilityIdentifier("\(identifier).tickets")
            Picker(String(localized: "Change projects", bundle: #bundle), selection: $projectChanges) {
                ForEach(ChangePermission.allCases) { permission in
                    Text(permission.title).tag(permission)
                }
            }
            .accessibilityIdentifier("\(identifier).projects")
            Picker(String(localized: "Call APIs that change data", bundle: #bundle), selection: $apiCalls) {
                ForEach(ChangePermission.allCases) { permission in
                    Text(permission.title).tag(permission)
                }
            }
            .accessibilityIdentifier("\(identifier).apiCalls")
            Picker(String(localized: "Operate deployments", bundle: #bundle), selection: $clusterChanges) {
                ForEach(ChangePermission.allCases) { permission in
                    Text(permission.title).tag(permission)
                }
            }
            .accessibilityIdentifier("\(identifier).clusters")
            Picker(String(localized: "Operate virtual machines", bundle: #bundle), selection: $machineChanges) {
                ForEach(ChangePermission.allCases) { permission in
                    Text(permission.title).tag(permission)
                }
            }
            .accessibilityIdentifier("\(identifier).machines")
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
            Text("Claude acts through each tool, as you would, and has Claude Code's own tools: files, commands, the web and agents. Outside the project's folder, and for a command, it asks first as the chat's permissions say.", bundle: #bundle)
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
    ChatSettingsView(previewStatus: ClaudeStatus(path: "/Users/you/.local/bin/claude", version: "2.1.322"))
}

#Preview("Settings, CLI Not Found", traits: .appChrome, .fixedLayout(width: 520, height: 440)) {
    ChatSettingsView(previewStatus: ClaudeStatus(error: "Claude CLI not found. Install Claude Code, or set its path in Settings ▸ Chat."))
}

#Preview("Settings, Looking", traits: .appChrome, .fixedLayout(width: 520, height: 440)) {
    ChatSettingsView(previewStatus: .checking)
}

#Preview("Settings, Dark", traits: .appChrome, .fixedLayout(width: 520, height: 440)) {
    ChatSettingsView(previewStatus: ClaudeStatus(path: "/Users/you/.local/bin/claude", version: "2.1.322"))
        .preferredColorScheme(.dark)
}

#Preview("Settings, Largest Text", traits: .largestText, .fixedLayout(width: 520, height: 440)) {
    ChatSettingsView(previewStatus: ClaudeStatus(path: "/Users/you/.local/bin/claude", version: "2.1.322"))
}
