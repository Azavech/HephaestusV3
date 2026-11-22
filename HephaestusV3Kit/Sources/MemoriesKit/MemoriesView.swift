import AppKit
import AZDesign
import MemoryData
import SwiftUI
import TextViews
import ToolsFoundation

/// Memories (docs/ui/memories.md): the global memories and each project's on the left, the shown folder's memories
/// in the middle, the selected one on the right.
public struct MemoriesView: View {
    @State private var model: MemoriesModel
    @State private var createsMemory = false
    @State private var deletes: MemorySummary?
    @State private var deleteFailure: String?

    /// The model a tab keeps.
    public init(state: MemoriesTabState) {
        _model = State(initialValue: state.model)
    }

    init(model: MemoriesModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        NavigationSplitView {
            scopes
        } content: {
            list
        } detail: {
            detail
        }
        .navigationTitle(Text("Memories", bundle: #bundle))
        .background(.canvas)
        .onAppear { model.startWatching() }
        .onDisappear { model.stopWatching() }
        // A route selects a scope, also when the tab is already open: `global` or a project's id.
        .onFocusRequest { focus in model.select(MemoryScope(focus: focus)) }
        .sheet(isPresented: $createsMemory) {
            NewMemorySheet(model: model)
        }
        .alert(Text("Move “\(deletes?.name ?? "")” to the Trash?", bundle: #bundle),
               isPresented: Binding(get: { deletes != nil }, set: { if !$0 { deletes = nil } }), presenting: deletes) { memory in
            Button(String(localized: "Move to Trash", bundle: #bundle), role: .destructive) {
                do throws(MemoryFileError) {
                    try model.delete(memory.file)
                } catch {
                    deleteFailure = error.reason
                }
            }
            Button(String(localized: "Cancel", bundle: #bundle), role: .cancel) {}
        }
        .alert(String(localized: "Move to Trash failed", bundle: #bundle),
               isPresented: Binding(get: { deleteFailure != nil }, set: { if !$0 { deleteFailure = nil } })) {
            Button(String(localized: "OK", bundle: #bundle)) { deleteFailure = nil }
        } message: {
            Text(verbatim: deleteFailure ?? "")
        }
    }

    // MARK: Scopes

    private var scopes: some View {
        List(selection: Binding<MemoryScope?> { model.scope } set: { if let scope = $0 { model.select(scope) } }) {
            Label(String(localized: "Global Memories", bundle: #bundle), systemImage: "globe")
                .tag(MemoryScope.global)
                .accessibilityIdentifier("memories.scope.global")
            Section(String(localized: "Projects", bundle: #bundle)) {
                // In tree order, each sub project under its parent, indented.
                ForEach(model.directory.tree.ordered(), id: \.project.id) { entry in
                    Label(entry.project.name, systemImage: entry.project.symbol)
                        .padding(.leading, CGFloat(entry.depth) * 14)
                        .tag(MemoryScope.project(entry.project.id))
                        .accessibilityIdentifier("memories.scope.\(entry.project.id)")
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 300)
        .accessibilityIdentifier("memories.scopes")
    }

    // MARK: List

    @ViewBuilder private var list: some View {
        Group {
            if let failure = model.listFailure {
                ContentUnavailableView {
                    Label(String(localized: "Memories Unavailable", bundle: #bundle), systemImage: "exclamationmark.triangle")
                } description: {
                    Text(verbatim: failure)
                }
            } else if model.isEmpty {
                emptyState
            } else {
                rows
            }
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 400)
    }

    private var rows: some View {
        List(selection: Binding<MemoryRow?> { model.selection } set: { model.select(row: $0) }) {
            if model.showsIndexRow {
                MemoryRowView(name: MemoryFolder.indexName, description: nil)
                    .tag(MemoryRow.index)
                    .accessibilityIdentifier("memories.row.index")
            }
            ForEach(MemoryType.allCases) { type in
                let memories = model.memories(of: type)
                if !memories.isEmpty {
                    Section(type.title) {
                        ForEach(memories) { memory in
                            MemoryRowView(name: memory.name, description: memory.description)
                                .tag(MemoryRow.memory(memory.file))
                                .accessibilityIdentifier("memories.row.\(memory.file)")
                        }
                    }
                }
            }
            ForEach(model.inheritedGroups, id: \.folder) { group in
                Section(String(localized: "Inherited from \(model.name(of: group.folder.projectID))", bundle: #bundle)) {
                    ForEach(group.memories) { memory in
                        MemoryRowView(name: memory.name, description: memory.description)
                            .tag(MemoryRow.inherited(projectID: group.folder.projectID, file: memory.file))
                            .accessibilityIdentifier("memories.row.\(group.folder.projectID)/\(memory.file)")
                    }
                }
            }
        }
        .overlay {
            if !model.hasMatches, !model.filter.isEmpty {
                ContentUnavailableView.search(text: model.filter)
            }
        }
        .onDeleteCommand {
            if let file = model.deletableFile { deletes = model.listing?.memories.first { $0.file == file } }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            TextField(String(localized: "Filter", bundle: #bundle), text: $model.filter)
                .textFieldStyle(.roundedBorder)
                .padding(8)
                .accessibilityIdentifier("memories.filter")
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 4) {
                Button(String(localized: "New Memory…", bundle: #bundle), systemImage: "plus") {
                    model.saveNow()
                    createsMemory = true
                }
                .help(String(localized: "New Memory…", bundle: #bundle))
                .accessibilityIdentifier("memories.new")
                Button(String(localized: "Move to Trash…", bundle: #bundle), systemImage: "minus") {
                    if let file = model.deletableFile { deletes = model.listing?.memories.first { $0.file == file } }
                }
                .help(String(localized: "Move to Trash…", bundle: #bundle))
                .disabled(model.deletableFile == nil)
                .accessibilityIdentifier("memories.delete")
                Spacer()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)
        }
        .accessibilityIdentifier("memories.list")
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(model.scope == .global ? String(localized: "No Global Memories", bundle: #bundle) : String(localized: "No Memories", bundle: #bundle),
                  systemImage: "brain")
        } description: {
            if model.scope == .global {
                Text("Claude saves here what it learns that holds for every project.", bundle: #bundle)
            } else {
                Text("Claude saves what it learns about you and this project in \(model.abbreviated(model.folder)).", bundle: #bundle)
            }
        } actions: {
            Button(String(localized: "New Memory…", bundle: #bundle)) { createsMemory = true }
                .accessibilityIdentifier("memories.empty.new")
        }
        .accessibilityIdentifier("memories.empty")
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if let shown = model.shown {
            if let failure = model.loadFailure {
                ContentUnavailableView {
                    Label(failure, systemImage: "doc.questionmark")
                } actions: {
                    Button(String(localized: "Try Again", bundle: #bundle)) { model.reload() }
                }
                .accessibilityIdentifier("memories.loadFailure")
            } else {
                MemoryEditor(model: model, shown: shown)
                    .id(shown.path)
            }
        } else {
            Text("Select a memory", bundle: #bundle)
                .font(.title3)
                .foregroundStyle(.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.canvas)
                .accessibilityIdentifier("memories.nothing")
        }
    }
}

extension MemoryType {
    var title: String {
        switch self {
        case .user: String(localized: "User", bundle: #bundle, comment: "A memory's type")
        case .feedback: String(localized: "Feedback", bundle: #bundle, comment: "A memory's type")
        case .project: String(localized: "Project", bundle: #bundle, comment: "A memory's type")
        case .reference: String(localized: "Reference", bundle: #bundle, comment: "A memory's type")
        case .other: String(localized: "Other", bundle: #bundle, comment: "A memory's type")
        }
    }
}

/// A row: the memory's name, its description under it on one line.
private struct MemoryRowView: View {
    let name: String
    let description: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: name)
            if let description, !description.isEmpty {
                Text(verbatim: description)
                    .font(.callout)
                    .foregroundStyle(.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.vertical, 2)
    }
}

/// A memory's name, description, type, other front matter and body, or `MEMORY.md`'s text; read-only for an
/// inherited memory. A change is saved by itself: the description and the body a second after the last keystroke,
/// the type at once, the name on Return or when its field loses the focus.
private struct MemoryEditor: View {
    @Bindable var model: MemoriesModel
    let shown: ShownFile
    @FocusState private var nameFocused: Bool

    private var isIndex: Bool { shown.row == .index }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isIndex {
                Text(verbatim: MemoryFolder.indexName)
                    .font(.title3.weight(.semibold))
                    .accessibilityIdentifier("memories.indexTitle")
            } else {
                fields
            }
            bodyEditor
            footer
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.canvas)
    }

    @ViewBuilder private var fields: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(String(localized: "Name", bundle: #bundle), text: $model.draft.name)
                .font(.title3.weight(.semibold))
                .textFieldStyle(.plain)
                .focused($nameFocused)
                .onSubmit { model.commitName() }
                .onChange(of: nameFocused) { if !nameFocused { model.commitName() } }
                .disabled(shown.isReadOnly)
                .accessibilityIdentifier("memories.name")
            if let message = model.nameMessage {
                Text(verbatim: message)
                    .font(.callout)
                    .foregroundStyle(.danger)
                    .accessibilityIdentifier("memories.nameMessage")
            }
        }
        VStack(alignment: .leading, spacing: 4) {
            TextField(String(localized: "Description", bundle: #bundle), text: $model.draft.description, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .onChange(of: model.draft.description) { model.edited() }
                .disabled(shown.isReadOnly)
                .accessibilityIdentifier("memories.description")
            if let message = model.descriptionMessage {
                Text(verbatim: message)
                    .font(.callout)
                    .foregroundStyle(.danger)
            }
        }
        Picker(String(localized: "Type", bundle: #bundle), selection: Binding<MemoryType?> {
            model.draft.type == .other ? nil : model.draft.type
        } set: { type in
            if let type { model.setType(type) }
        }) {
            ForEach(MemoryType.chosen) { type in
                Text(type.title).tag(MemoryType?.some(type))
            }
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .disabled(shown.isReadOnly)
        .accessibilityIdentifier("memories.type")
        if !model.otherFrontMatter.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Other Front Matter", bundle: #bundle)
                    .font(.callout)
                    .foregroundStyle(.textSecondary)
                Text(verbatim: model.otherFrontMatter)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.surfaceSunken, in: .rect(cornerRadius: 6))
            }
            .accessibilityIdentifier("memories.otherFrontMatter")
        }
    }

    private var mode: MemoryBodyMode { shown.isReadOnly ? .preview : model.bodyMode }

    @ViewBuilder private var bodyEditor: some View {
        Picker(String(localized: "Mode", bundle: #bundle), selection: $model.bodyMode) {
            Text("Edit", bundle: #bundle).tag(MemoryBodyMode.edit)
            Text("Preview", bundle: #bundle).tag(MemoryBodyMode.preview)
            Text("Split", bundle: #bundle).tag(MemoryBodyMode.split)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .disabled(shown.isReadOnly)
        .accessibilityIdentifier("memories.mode")
        HStack(spacing: 12) {
            if mode != .preview {
                TextEditor(text: $model.draft.body)
                    .font(.body.monospaced())
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.surfaceSunken, in: .rect(cornerRadius: 8))
                    .onChange(of: model.draft.body) { model.edited() }
                    .accessibilityLabel(Text("Body", bundle: #bundle))
                    .accessibilityIdentifier("memories.body")
            }
            if mode != .edit {
                ScrollView {
                    MarkdownView(model.draft.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .background(.surface, in: .rect(cornerRadius: 8))
                .accessibilityIdentifier("memories.preview")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: model.abbreviated(shown.path))
                .font(.callout)
                .foregroundStyle(.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .accessibilityIdentifier("memories.path")
            Button(String(localized: "Reveal in Finder", bundle: #bundle)) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: shown.path)])
            }
            .buttonStyle(.link)
            .accessibilityIdentifier("memories.reveal")
            Spacer()
            // The status keeps its room; the path is cut in the middle first.
            status
                .layoutPriority(1)
        }
    }

    @ViewBuilder private var status: some View {
        if shown.isReadOnly, case .inherited(let projectID, _) = shown.row {
            Text("Read only: edit it in \(model.name(of: projectID)).", bundle: #bundle)
                .font(.callout)
                .lineLimit(1)
                .foregroundStyle(.textSecondary)
                .accessibilityIdentifier("memories.status")
        } else if let failure = model.saveFailure {
            Label {
                Text("Not saved: \(failure)", bundle: #bundle)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.callout)
            .foregroundStyle(.danger)
            .accessibilityIdentifier("memories.status")
        } else {
            Text(model.hasUnsavedChanges ? String(localized: "Editing…", bundle: #bundle) : String(localized: "Saved", bundle: #bundle))
                .font(.callout)
                .foregroundStyle(.textSecondary)
                .accessibilityIdentifier("memories.status")
        }
    }
}

/// New Memory: its name, description and type; Create writes it and its `MEMORY.md` line.
private struct NewMemorySheet: View {
    let model: MemoriesModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var type: MemoryType?
    @State private var failure: String?

    private var nameMessage: String? { model.newNameMessage(name) }
    private var canCreate: Bool {
        !name.isEmpty && nameMessage == nil && !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && type != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Memory", bundle: #bundle)
                .font(.title3.weight(.semibold))
            Form {
                TextField(String(localized: "Name", bundle: #bundle), text: $name)
                    .onSubmit(create)
                    .accessibilityIdentifier("memories.newName")
                if let nameMessage {
                    Text(verbatim: nameMessage)
                        .font(.callout)
                        .foregroundStyle(.danger)
                }
                TextField(String(localized: "Description", bundle: #bundle), text: $description, axis: .vertical)
                    .lineLimit(2...5)
                    .accessibilityIdentifier("memories.newDescription")
                Picker(String(localized: "Type", bundle: #bundle), selection: $type) {
                    ForEach(MemoryType.chosen) { type in
                        Text(type.title).tag(MemoryType?.some(type))
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("memories.newType")
            }
            if let failure {
                Text(verbatim: failure)
                    .font(.callout)
                    .foregroundStyle(.danger)
            }
            HStack {
                Spacer()
                Button(String(localized: "Cancel", bundle: #bundle), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Create", bundle: #bundle), action: create)
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canCreate)
                    .accessibilityIdentifier("memories.create")
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func create() {
        guard canCreate, let type else { return }
        do throws(MemoryFileError) {
            try model.create(name: name, description: description, type: type)
            dismiss()
        } catch {
            failure = error.reason
        }
    }
}
