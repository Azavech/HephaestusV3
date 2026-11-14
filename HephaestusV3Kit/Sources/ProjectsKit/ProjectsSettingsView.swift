import AppKit
import AZDesign
import ExternalTools
import ProjectData
import SwiftUI
import ToolsFoundation

/// Settings ▸ Projects: where the app keeps its data, the login shell's environment the tools run in, and the
/// tools found in it, with Look Again.
public struct ProjectsSettingsPane: View {
    let session: ProjectSession

    public init(session: ProjectSession) {
        self.session = session
    }

    public var body: some View {
        ProjectsSettingsView(
            dataFolder: session.dataFolder?.url.path, importedCount: session.importResult?.imported.count,
            shell: session.shell, tools: session.tools, isLookingUp: session.isLookingUpTools
        ) {
            Task { await session.lookUpTools() }
        }
    }
}

/// The pane's content, from plain values, so previews show every state.
struct ProjectsSettingsView: View {
    let dataFolder: String?
    /// The projects brought over from V2 at this launch; nil when the import didn't run.
    let importedCount: Int?
    let shell: ShellEnvironment.Capture?
    let tools: Tools
    let isLookingUp: Bool
    let lookAgain: () -> Void

    var body: some View {
        Form {
            Section(String(localized: "Data", bundle: #bundle)) {
                LabeledContent(String(localized: "Data Folder", bundle: #bundle)) {
                    if let dataFolder {
                        HStack(spacing: 8) {
                            Text(verbatim: dataFolder)
                                .monospaced()
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            Button(String(localized: "Show in Finder", bundle: #bundle)) {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: dataFolder)])
                            }
                            .accessibilityIdentifier("settings.projects.showDataFolder")
                        }
                    } else {
                        Text("No data folder", bundle: #bundle, comment: "Settings ▸ Projects without a data folder")
                            .foregroundStyle(.textSecondary)
                    }
                }
                .accessibilityIdentifier("settings.projects.dataFolder")
                if let importedCount {
                    LabeledContent(String(localized: "From HephaestusV2", bundle: #bundle)) {
                        Text("^[\(importedCount) project](inflect: true) brought over at this launch", bundle: #bundle)
                    }
                    .accessibilityIdentifier("settings.projects.import")
                }
            }
            Section {
                LabeledContent(String(localized: "Login Shell", bundle: #bundle)) {
                    shellStatus
                }
                .accessibilityIdentifier("settings.projects.shell")
                ForEach(rows, id: \.name) { row in
                    LabeledContent {
                        if let path = row.path {
                            Text(verbatim: path)
                                .monospaced()
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        } else {
                            Text("Not found", bundle: #bundle, comment: "A command-line tool the app didn't find")
                                .foregroundStyle(.textSecondary)
                        }
                    } label: {
                        Text(verbatim: row.name)
                            .monospaced()
                    }
                    .accessibilityIdentifier("settings.projects.tool.\(row.name)")
                }
            } header: {
                Text("Command-Line Tools", bundle: #bundle)
            } footer: {
                HStack {
                    Text("Found in the PATH of your login shell, as in Terminal.", bundle: #bundle)
                        .foregroundStyle(.textSecondary)
                    Spacer()
                    Button(String(localized: "Look Again", bundle: #bundle), action: lookAgain)
                        .disabled(isLookingUp)
                        .accessibilityIdentifier("settings.projects.lookAgain")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var rows: [(name: String, path: String?)] {
        [("git", tools.git), ("ssh", tools.ssh), ("kubectl", tools.kubectl), ("gh", tools.gh)]
    }

    @ViewBuilder private var shellStatus: some View {
        if isLookingUp || shell == nil {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Reading…", bundle: #bundle, comment: "The login shell's environment is being read")
            }
        } else if let shell {
            switch shell.outcome {
            case .captured(let count):
                Label {
                    Text("^[\(count) variable](inflect: true) read", bundle: #bundle)
                } icon: {
                    StatusDot(.success)
                }
            case .timedOut:
                fallback(Text("Took too long; the tools run with the app’s own environment.", bundle: #bundle))
            case .failed(let termination):
                fallback(Text("Failed with code \(termination.code); the tools run with the app’s own environment.", bundle: #bundle))
            case .empty:
                fallback(Text("Gave nothing; the tools run with the app’s own environment.", bundle: #bundle))
            case .couldNotStart:
                fallback(Text("Couldn’t start zsh; the tools run with the app’s own environment.", bundle: #bundle))
            }
        }
    }

    private func fallback(_ text: Text) -> some View {
        Label {
            text
        } icon: {
            StatusDot(.warning)
        }
    }
}

// MARK: - Previews

private let previewTools = Tools(environment: [:], git: "/opt/homebrew/bin/git", ssh: "/usr/bin/ssh",
                                 kubectl: "/opt/homebrew/bin/kubectl", gh: nil)

#Preview("Found", traits: .fixedLayout(width: 520, height: 440)) {
    ProjectsSettingsView(
        dataFolder: "/Users/example/Library/Group Containers/group.fr.azavech.hephaestusv3", importedCount: 4,
        shell: .init(environment: [:], outcome: .captured(count: 42)), tools: previewTools, isLookingUp: false
    ) {}
}

#Preview("Reading", traits: .fixedLayout(width: 520, height: 440)) {
    ProjectsSettingsView(
        dataFolder: "/Users/example/Library/Group Containers/group.fr.azavech.hephaestusv3", importedCount: nil,
        shell: nil, tools: .notLookedUp, isLookingUp: true
    ) {}
}

#Preview("Shell Failed, Dark", traits: .fixedLayout(width: 520, height: 440)) {
    ProjectsSettingsView(
        dataFolder: nil, importedCount: nil, shell: .init(environment: [:], outcome: .timedOut),
        tools: Tools(environment: [:], ssh: "/usr/bin/ssh"), isLookingUp: false
    ) {}
    .preferredColorScheme(.dark)
}
