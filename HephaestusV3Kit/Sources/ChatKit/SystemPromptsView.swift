import AZDesign
import ChatData
import FileStorage
import Observation
import ProjectData
import SwiftUI
import ToolsFoundation

/// Where System Prompts reads and writes the internal skills' values: the data folder in the app, memory in
/// previews and tests.
@MainActor
protocol InternalSkillStore: AnyObject {
    func values(of skill: InternalSkill) -> InternalSkillValues
    func save(_ values: InternalSkillValues, of skill: InternalSkill) throws(StorageError)
}

/// The internal skills of the app's data folder (docs/data.md › Internal skills).
@MainActor
public final class LiveInternalSkillStore: InternalSkillStore {
    private let folder: DataFolder?

    /// `dataFolder` nil, when the app has none, shows the defaults and stores nothing.
    public init(dataFolder: DataFolder?) {
        folder = dataFolder
    }

    func values(of skill: InternalSkill) -> InternalSkillValues {
        folder?.readSkill(skill) ?? skill.defaults
    }

    func save(_ values: InternalSkillValues, of skill: InternalSkill) throws(StorageError) {
        guard let folder else {
            throw .writeFailed(path: "skills/\(skill.name)/SKILL.md", reason: String(localized: "The app has no data folder.", bundle: #bundle))
        }
        try folder.writeSkill(values, of: skill)
    }
}

/// The skills' values in memory.
@MainActor
final class SampleInternalSkillStore: InternalSkillStore {
    private(set) var saved: [String: InternalSkillValues]
    /// The error every save throws, when set.
    var failure: StorageError?

    init(saved: [String: InternalSkillValues] = [:], failure: StorageError? = nil) {
        self.saved = saved
        self.failure = failure
    }

    /// Skills whose only change is their content.
    convenience init(contents: [String: String], failure: StorageError? = nil) {
        var saved: [String: InternalSkillValues] = [:]
        for skill in InternalSkill.all {
            if let content = contents[skill.name] {
                var values = skill.defaults
                values.content = content
                saved[skill.name] = values
            }
        }
        self.init(saved: saved, failure: failure)
    }

    func values(of skill: InternalSkill) -> InternalSkillValues {
        saved[skill.name] ?? skill.defaults
    }

    func save(_ values: InternalSkillValues, of skill: InternalSkill) throws(StorageError) {
        if let failure { throw failure }
        saved[skill.name] = values
    }
}

/// System Prompts: the internal skills the app defines, and the content, model and effort the user gives each
/// (docs/ui/system-prompts.md). A change of content is saved a second after the last keystroke; a change of
/// model or effort at once; every change when another skill is selected and when the tab goes away.
@MainActor
@Observable
final class SystemPromptsModel {
    let skills: [InternalSkill]
    var selection: InternalSkill.ID?
    /// The values as shown, by skill name.
    private(set) var values: [String: InternalSkillValues]
    /// The values as stored.
    private var stored: [String: InternalSkillValues]
    /// Why the last save failed, by skill name.
    private(set) var failures: [String: String] = [:]

    @ObservationIgnored private let store: any InternalSkillStore
    @ObservationIgnored private var pending: [String: Task<Void, Never>] = [:]
    /// How long after the last keystroke a skill's content is saved.
    @ObservationIgnored let saveDelay: Duration

    init(skills: [InternalSkill] = InternalSkill.all, store: any InternalSkillStore, saveDelay: Duration = .seconds(1)) {
        self.skills = skills
        self.store = store
        self.saveDelay = saveDelay
        let values = Dictionary(uniqueKeysWithValues: skills.map { ($0.name, store.values(of: $0)) })
        self.values = values
        stored = values
        selection = skills.first?.id
    }

    var selected: InternalSkill? {
        skills.first { $0.id == selection }
    }

    func values(of skill: InternalSkill) -> InternalSkillValues {
        values[skill.name] ?? skill.defaults
    }

    func content(of skill: InternalSkill) -> String {
        values(of: skill).content
    }

    /// Whether what shows is stored.
    func isSaved(_ skill: InternalSkill) -> Bool {
        values[skill.name] == stored[skill.name]
    }

    /// The user's typing: shown at once, saved after `saveDelay` without another change.
    func setContent(_ content: String, of skill: InternalSkill) {
        guard values(of: skill).content != content else { return }
        values[skill.name, default: skill.defaults].content = content
        pending[skill.name]?.cancel()
        pending[skill.name] = Task { [weak self, saveDelay] in
            try? await Task.sleep(for: saveDelay)
            guard !Task.isCancelled else { return }
            self?.save(skill)
        }
    }

    /// The model used when the app runs the skill itself: saved at once.
    func setModel(_ model: String, of skill: InternalSkill) {
        guard values(of: skill).model != model else { return }
        values[skill.name, default: skill.defaults].model = model
        save(skill)
    }

    /// The effort used when the app runs the skill itself: saved at once.
    func setEffort(_ effort: Effort, of skill: InternalSkill) {
        guard values(of: skill).effort != effort else { return }
        values[skill.name, default: skill.defaults].effort = effort
        save(skill)
    }

    /// Whether the skill's content, model and effort are the app's own.
    func isDefault(_ skill: InternalSkill) -> Bool {
        let current = values(of: skill)
        return current.content == skill.defaults.content && current.model == skill.defaults.model && current.effort == skill.defaults.effort
    }

    /// Restore Default: the app's content, model and effort, saved at once; the file's other front matter lines stay.
    func restoreDefaults(of skill: InternalSkill) {
        var restored = skill.defaults
        restored.otherLines = values(of: skill).otherLines
        values[skill.name] = restored
        save(skill)
    }

    /// Saves a skill now when it has a change.
    func save(_ skill: InternalSkill) {
        pending[skill.name]?.cancel()
        pending[skill.name] = nil
        guard let current = values[skill.name], current != stored[skill.name] else { return }
        do throws(StorageError) {
            try store.save(current, of: skill)
            stored[skill.name] = current
            failures[skill.name] = nil
        } catch {
            failures[skill.name] = error.description
        }
    }

    /// Saves every change now: when another skill is selected, or the tab goes away.
    func saveAll() {
        for skill in skills {
            save(skill)
        }
    }
}

/// What a tab keeps of System Prompts while another tab is in front: its model, so that the selected skill and
/// what is typed are still there when the tab comes back, as V2's window kept them. The app's window makes one per tab.
@MainActor
public final class SystemPromptsTabState {
    let model: SystemPromptsModel

    public init(store: LiveInternalSkillStore) {
        model = SystemPromptsModel(store: store)
    }
}

/// System Prompts: the internal skills on the left, the selected one's name and content on the right. The app's
/// code defines the skills; the user edits their content (docs/ui/system-prompts.md).
public struct SystemPromptsView: View {
    @State private var model: SystemPromptsModel

    /// The skills of the app's data folder.
    public init(store: LiveInternalSkillStore) {
        _model = State(initialValue: SystemPromptsModel(store: store))
    }

    /// The model a tab keeps.
    public init(state: SystemPromptsTabState) {
        _model = State(initialValue: state.model)
    }

    init(model: SystemPromptsModel) {
        _model = State(initialValue: model)
    }

    @Environment(\.chatStore) private var chatStore

    public var body: some View {
        splitView
            // A route to a skill selects it, by its name, also when the tab is already open.
            .onFocusRequest { name in
                if model.skills.contains(where: { $0.name == name }) { model.selection = name }
            }
    }

    private var splitView: some View {
        NavigationSplitView {
            List(model.skills, selection: $model.selection) { skill in
                Label {
                    Text(verbatim: skill.name)
                        .monospaced()
                } icon: {
                    Image(systemName: "text.book.closed")
                }
                .tag(skill.id)
                .accessibilityIdentifier("systemPrompts.skill.\(skill.name)")
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
            .accessibilityIdentifier("systemPrompts.list")
        } detail: {
            if let skill = model.selected {
                SkillEditor(
                    skill: skill,
                    content: Binding { model.content(of: skill) } set: { model.setContent($0, of: skill) },
                    models: models,
                    settings: ChatSettings(model: model.values(of: skill).model, effort: model.values(of: skill).effort),
                    setSettings: { settings in
                        model.setModel(settings.model, of: skill)
                        model.setEffort(settings.effort, of: skill)
                    },
                    isSaved: model.isSaved(skill),
                    failure: model.failures[skill.name],
                    isDefault: model.isDefault(skill),
                    restoreDefaults: { model.restoreDefaults(of: skill) }
                )
                .id(skill.id)
            } else {
                ContentUnavailableView {
                    Label(String(localized: "No Skill Selected", bundle: #bundle), systemImage: "text.book.closed")
                } description: {
                    Text("Select an internal skill to edit its content.", bundle: #bundle)
                }
                .accessibilityIdentifier("systemPrompts.nothing")
            }
        }
        .navigationTitle(Text("System Prompts", bundle: #bundle))
        .onChange(of: model.selection) {
            model.saveAll()
        }
        .onDisappear {
            model.saveAll()
        }
        .background(.canvas)
    }

    /// The CLI's models, as Settings ▸ Chat lists them; its fallback list until the CLI has answered.
    private var models: [ClaudeModel] {
        let models = chatStore?.models ?? []
        return models.isEmpty ? ClaudeModel.fallback : models
    }
}

/// A skill's name, which the app defines; the model and effort the app runs it with; its content, which the
/// user writes.
private struct SkillEditor: View {
    let skill: InternalSkill
    @Binding var content: String
    let models: [ClaudeModel]
    let settings: ChatSettings
    let setSettings: (ChatSettings) -> Void
    let isSaved: Bool
    let failure: String?
    let isDefault: Bool
    let restoreDefaults: () -> Void
    @State private var confirmsRestore = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent(String(localized: "Name", bundle: #bundle)) {
                Text(verbatim: skill.name)
                    .monospaced()
                    .textSelection(.enabled)
            }
            .help(String(localized: "The app defines this skill and its name.", bundle: #bundle))
            .accessibilityIdentifier("systemPrompts.name")

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 20) {
                    ReplySettingsRows(models: models, settings: settings, identifier: "systemPrompts", set: setSettings)
                        .fixedSize()
                }
                Text("Used when the app runs this skill itself; a chat that calls it keeps its own model and effort.", bundle: #bundle)
                    .font(.caption)
                    .foregroundStyle(.textSecondary)
            }

            TextEditor(text: $content)
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.surfaceSunken, in: .rect(corners: .concentric(minimum: .fixed(8)), isUniform: true))
                .overlay(alignment: .topLeading) {
                    if content.isEmpty {
                        Text("Empty: Claude gets nothing from this skill.", bundle: #bundle)
                            .font(.body.monospaced())
                            .foregroundStyle(.textSecondary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(Text("Content", bundle: #bundle))
                .accessibilityIdentifier("systemPrompts.content")

            HStack(alignment: .firstTextBaseline) {
                status
                Spacer()
                Button(String(localized: "Restore Default", bundle: #bundle)) {
                    confirmsRestore = true
                }
                .disabled(isDefault)
                .help(String(localized: "Gives this skill the app's content, model and effort back.", bundle: #bundle))
                .accessibilityIdentifier("systemPrompts.restoreDefault")
            }
        }
        .confirmationDialog(
            String(localized: "Restore the default content, model and effort of \(skill.name)?", bundle: #bundle),
            isPresented: $confirmsRestore
        ) {
            Button(String(localized: "Restore Default", bundle: #bundle), role: .destructive, action: restoreDefaults)
        } message: {
            Text("What you wrote in this skill is replaced by the app's own text.", bundle: #bundle)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.canvas)
    }

    @ViewBuilder private var status: some View {
        if let failure {
            Label {
                Text("Not saved: \(failure)", bundle: #bundle)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.callout)
            .foregroundStyle(.danger)
            .accessibilityIdentifier("systemPrompts.status")
        } else {
            Text(isSaved ? String(localized: "Saved", bundle: #bundle) : String(localized: "Editing…", bundle: #bundle))
                .font(.callout)
                .foregroundStyle(.textSecondary)
                .accessibilityIdentifier("systemPrompts.status")
        }
    }
}

// MARK: Previews

#Preview("Defaults", traits: .fixedLayout(width: 900, height: 560)) {
    SystemPromptsView(model: SystemPromptsModel(store: SampleInternalSkillStore()))
}

#Preview("Report Feedback, Empty", traits: .fixedLayout(width: 900, height: 560)) {
    let model = SystemPromptsModel(store: SampleInternalSkillStore())
    model.selection = InternalSkill.reportFeedback.id
    return SystemPromptsView(model: model)
}

#Preview("Written, Dark", traits: .fixedLayout(width: 900, height: 560)) {
    SystemPromptsView(model: SystemPromptsModel(store: SampleInternalSkillStore(contents: [
        "set-ticket-title": "Give the ticket a title of at most 60 characters, from its description.\n\nWrite it as a short sentence, without a final period."
    ])))
    .preferredColorScheme(.dark)
}

#Preview("Not Saved", traits: .fixedLayout(width: 900, height: 560)) {
    let model = SystemPromptsModel(
        store: SampleInternalSkillStore(failure: .writeFailed(path: "skills/set-ticket-title/SKILL.md", reason: "Permission denied")),
        saveDelay: .zero
    )
    model.setContent("A change that can't be stored.", of: .setTicketTitle)
    model.save(.setTicketTitle)
    return SystemPromptsView(model: model)
}
