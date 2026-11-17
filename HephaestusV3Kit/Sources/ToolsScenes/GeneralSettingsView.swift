import AZDesign
import FileStorage
import ProjectData
import SwiftUI
import ToolsFoundation

/// Settings ▸ General on the app's data.
struct GeneralSettingsPane: View {
    let appData: AppData

    var body: some View {
        GeneralSettingsView(
            opensWindowsAsTabs: appData.opensWindowsAsTabs,
            feedbackProjectID: appData.feedbackProjectID,
            projects: appData.directory.projects.map {
                GeneralSettingsView.ProjectChoice(id: $0.id, title: appData.directory.tree.path(of: $0.id))
            },
            change: { value throws(StorageError) in try appData.setOpensWindowsAsTabs(value) },
            changeFeedbackProject: { id throws(StorageError) in try appData.setFeedbackProject(id) }
        )
    }
}

/// Settings ▸ General: how the windows the app opens appear, and where feedback goes
/// (docs/ui/navigation.md › Settings ▸ General).
struct GeneralSettingsView: View {
    /// A project the feedback can go to, named by its path in the tree ("Shop › Orders").
    struct ProjectChoice: Identifiable, Hashable {
        let id: Project.ID
        let title: String
    }

    let opensWindowsAsTabs: Bool
    let feedbackProjectID: Project.ID?
    let projects: [ProjectChoice]
    let change: (Bool) throws(StorageError) -> Void
    var changeFeedbackProject: (Project.ID?) throws(StorageError) -> Void = { _ in }

    @State private var message: String?
    @State private var feedbackMessage: String?

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
                Text("Applies to what Hephaestus opens: a tool, a project, its settings. Window ▸ Merge All Windows and Move Tab to New Window work either way.", bundle: #bundle)
                    .font(.callout)
                    .foregroundStyle(.textSecondary)
            }

            Section {
                Picker(String(localized: "Feedback project", bundle: #bundle), selection: feedbackSelection) {
                    Text("None", bundle: #bundle).tag(Project.ID?.none)
                    if let feedbackProjectID, !projects.contains(where: { $0.id == feedbackProjectID }) {
                        Text("\(feedbackProjectID) (not loaded)", bundle: #bundle).tag(Project.ID?.some(feedbackProjectID))
                    }
                    ForEach(projects) { project in
                        Text(verbatim: project.title).tag(Project.ID?.some(project.id))
                    }
                }
                .accessibilityIdentifier("settings.general.feedbackProject")
                if let feedbackMessage {
                    Text(verbatim: feedbackMessage)
                        .font(.callout)
                        .foregroundStyle(.danger)
                        .accessibilityIdentifier("settings.general.feedbackMessage")
                }
            } header: {
                Text("Feedback", bundle: #bundle)
            } footer: {
                Text("The ladybug at the bottom of every window, and Help ▸ Send Feedback… (⇧⌘B), start a chat in this project about the window, with its screenshot, which calls the internal skill report-feedback. With None, neither shows.", bundle: #bundle)
                    .font(.callout)
                    .foregroundStyle(.textSecondary)
            }
        }
        .formStyle(.grouped)
    }

    private var feedbackSelection: Binding<Project.ID?> {
        Binding {
            feedbackProjectID
        } set: { id in
            guard id != feedbackProjectID else { return }
            do throws(StorageError) {
                try changeFeedbackProject(id)
                feedbackMessage = nil
            } catch {
                feedbackMessage = error.description
            }
        }
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

private let previewProjects = Project.samples.map { GeneralSettingsView.ProjectChoice(id: $0.id, title: Project.tree.path(of: $0.id)) }

#Preview("Tabs", traits: .fixedLayout(width: 520, height: 440)) {
    GeneralSettingsView(opensWindowsAsTabs: true, feedbackProjectID: nil, projects: previewProjects) { _ in }
}

#Preview("Separate Windows, Feedback to Orders, Dark", traits: .fixedLayout(width: 520, height: 440)) {
    GeneralSettingsView(opensWindowsAsTabs: false, feedbackProjectID: "ORD", projects: previewProjects) { _ in }
        .preferredColorScheme(.dark)
}

#Preview("Feedback Project Not Loaded", traits: .fixedLayout(width: 520, height: 440)) {
    GeneralSettingsView(opensWindowsAsTabs: true, feedbackProjectID: "HV3", projects: previewProjects) { _ in }
}

#Preview("Not Stored", traits: .fixedLayout(width: 520, height: 440)) {
    GeneralSettingsView(opensWindowsAsTabs: true, feedbackProjectID: nil, projects: previewProjects) { _ throws(StorageError) in
        throw .writeFailed(path: "~/Library/Application Support/HephaestusV3/settings.yml", reason: "Permission denied")
    }
}
