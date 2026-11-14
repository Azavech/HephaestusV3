import AZDesign
import ProjectData
import SwiftUI
import ToolsFoundation
import UniformTypeIdentifiers

/// The New Project and New Sub Project sheet (docs/ui/projects.md › New Project).
struct NewProjectSheet: View {
    @State private var model: NewProjectModel
    /// Creates the project; returns its identifier.
    let create: (NewProject) async throws(ProjectError) -> String
    /// Adds the folder instead, when it holds a project already.
    let addInstead: (String) async throws(ProjectError) -> String
    /// Called with the new project's identifier once it is created or added.
    let done: (Project.ID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var error: ProjectError?
    @State private var isWorking = false

    init(model: NewProjectModel, create: @escaping (NewProject) async throws(ProjectError) -> String,
         addInstead: @escaping (String) async throws(ProjectError) -> String, done: @escaping (Project.ID) -> Void) {
        _model = State(initialValue: model)
        self.create = create
        self.addInstead = addInstead
        self.done = done
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if model.isSubProject {
                    parentPicker
                }
                Section {
                    TextField(String(localized: "Name", bundle: #bundle), text: $model.name)
                        .accessibilityIdentifier("newProject.name")
                    message(model.nameMessage)
                    LabeledContent(String(localized: "Identifier", bundle: #bundle)) {
                        TextField(String(localized: "Identifier", bundle: #bundle),
                                  text: Binding { model.identifier } set: { model.setIdentifier($0) })
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .monospaced()
                            .accessibilityIdentifier("newProject.identifier")
                    }
                    message(model.identifierMessage)
                    Picker(String(localized: "Type", bundle: #bundle),
                           selection: Binding { model.kind } set: { model.pickedKind = $0 }) {
                        ForEach(Project.Kind.allCases) { kind in
                            Label(kind.title, systemImage: kind.symbol).tag(kind)
                        }
                    }
                    .accessibilityIdentifier("newProject.type")
                    if !model.isSubProject {
                        parentPicker
                    }
                }
                Section(String(localized: "Folder", bundle: #bundle)) {
                    Picker(String(localized: "Folder", bundle: #bundle), selection: $model.folderMode) {
                        Text("New Folder", bundle: #bundle).tag(NewProjectModel.FolderMode.newFolder)
                        Text("Existing Folder", bundle: #bundle).tag(NewProjectModel.FolderMode.existingFolder)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityIdentifier("newProject.folderMode")
                    switch model.folderMode {
                    case .newFolder:
                        pathRow(String(localized: "Location", bundle: #bundle), path: model.location.path, choice: .location)
                        TextField(String(localized: "Folder Name", bundle: #bundle),
                                  text: Binding { model.folderName } set: { model.setFolderName($0) })
                            .accessibilityIdentifier("newProject.folderName")
                    case .existingFolder:
                        pathRow(String(localized: "Folder", bundle: #bundle), path: model.existingFolder?.path, choice: .existingFolder)
                    }
                    message(model.folderMessage)
                    LabeledContent(String(localized: "Project Folder", bundle: #bundle)) {
                        Text(verbatim: model.projectFolder ?? "—")
                            .monospaced()
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .foregroundStyle(.textSecondary)
                    }
                    .accessibilityIdentifier("newProject.projectFolder")
                    if let inside = model.insideProject {
                        Text("This folder is inside “\(inside.name)”: the new project becomes its sub project.", bundle: #bundle)
                            .font(.callout)
                            .foregroundStyle(.textSecondary)
                    }
                }
            }
            .formStyle(.grouped)
            footer
        }
        .frame(minWidth: 480, idealWidth: 520, minHeight: 440)
        // The panel's binding closes it before the result arrives: the field it fills is the model's.
        .fileImporter(isPresented: $model.choosingFolder, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            model.chose(url)
        }
        .accessibilityIdentifier("newProject")
    }

    private var parentPicker: some View {
        Picker(String(localized: "Parent Project", bundle: #bundle),
               selection: Binding { model.parentID } set: { model.pickParent($0) }) {
            if !model.isSubProject {
                Text("None", bundle: #bundle, comment: "No parent project").tag(Project.ID?.none)
                Divider()
            }
            ForEach(model.parentChoices, id: \.project.id) { choice in
                Text(verbatim: String(repeating: "    ", count: choice.depth) + choice.project.name)
                    .tag(Project.ID?.some(choice.project.id))
            }
        }
        .accessibilityIdentifier("newProject.parent")
    }

    private func pathRow(_ title: String, path: String?, choice: NewProjectModel.FolderChoice) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Text(verbatim: path ?? "")
                    .monospaced()
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.textSecondary)
                Button(String(localized: "Choose…", bundle: #bundle)) {
                    model.chooseFolder(for: choice)
                }
                .accessibilityIdentifier("newProject.choose")
            }
        }
    }

    @ViewBuilder private func message(_ text: String?) -> some View {
        if let text {
            Text(verbatim: text)
                .font(.callout)
                .foregroundStyle(.danger)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let error {
                Text(verbatim: ProjectMessages.message(error))
                    .font(.callout)
                    .foregroundStyle(.danger)
                    .accessibilityIdentifier("newProject.error")
                if case .alreadyContainsProject(let path) = error {
                    Button(String(localized: "Add It Instead", bundle: #bundle)) {
                        run { () throws(ProjectError) in try await addInstead(path) }
                    }
                    .accessibilityIdentifier("newProject.addInstead")
                }
            }
            Spacer()
            Button(String(localized: "Cancel", bundle: #bundle), role: .cancel) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button(String(localized: "Create", bundle: #bundle)) {
                guard let request = model.request else { return }
                run { () throws(ProjectError) in try await create(request) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canCreate || isWorking)
            .accessibilityIdentifier("newProject.create")
        }
        .padding(16)
    }

    private func run(_ action: @escaping () async throws(ProjectError) -> String) {
        isWorking = true
        Task {
            defer { isWorking = false }
            do throws(ProjectError) {
                let id = try await action()
                done(id)
                dismiss()
            } catch {
                self.error = error
            }
        }
    }
}

// MARK: - Previews

private func previewSheet(_ model: NewProjectModel) -> some View {
    NewProjectSheet(model: model, create: { _ throws(ProjectError) in "NEW" }, addInstead: { _ throws(ProjectError) in "NEW" }) { _ in }
}

#Preview("Empty", traits: .fixedLayout(width: 520, height: 520)) {
    previewSheet(NewProjectModel(projects: Project.samples, location: URL(fileURLWithPath: "/Users/example/Developer")))
}

#Preview("Filled", traits: .fixedLayout(width: 520, height: 520)) {
    let model = NewProjectModel(projects: Project.samples, location: URL(fileURLWithPath: "/Users/example/Developer"))
    model.name = "Inventory Service"
    return previewSheet(model)
}

#Preview("Sub Project, Dark", traits: .fixedLayout(width: 520, height: 560)) {
    let model = NewProjectModel(projects: Project.samples, location: URL(fileURLWithPath: "/Users/example/Developer"), parentID: "SHOP")
    model.name = "Checkout"
    return previewSheet(model)
        .preferredColorScheme(.dark)
}
