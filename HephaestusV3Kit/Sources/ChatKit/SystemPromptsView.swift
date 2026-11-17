import AZDesign
import ChatData
import FileStorage
import Observation
import ProjectData
import SwiftUI
import ToolsFoundation

/// Where System Prompts reads and writes the internal skills' content: the data folder in the app, memory in
/// previews and tests.
@MainActor
protocol InternalSkillStore: AnyObject {
    func content(of skill: InternalSkill) -> String
    func save(_ content: String, of skill: InternalSkill) throws(StorageError)
}

/// The internal skills of the app's data folder (docs/data.md › Internal skills).
@MainActor
public final class LiveInternalSkillStore: InternalSkillStore {
    private let folder: DataFolder?

    /// `dataFolder` nil, when the app has none, shows the default contents and stores nothing.
    public init(dataFolder: DataFolder?) {
        folder = dataFolder
    }

    func content(of skill: InternalSkill) -> String {
        folder?.readContent(of: skill) ?? skill.defaultContent
    }

    func save(_ content: String, of skill: InternalSkill) throws(StorageError) {
        guard let folder else {
            throw .writeFailed(path: "skills/\(skill.name)/SKILL.md", reason: String(localized: "The app has no data folder.", bundle: #bundle))
        }
        try folder.writeContent(content, of: skill)
    }
}

/// The skills' contents in memory.
@MainActor
final class SampleInternalSkillStore: InternalSkillStore {
    private(set) var contents: [String: String]
    /// The error every save throws, when set.
    var failure: StorageError?

    init(contents: [String: String] = [:], failure: StorageError? = nil) {
        self.contents = contents
        self.failure = failure
    }

    func content(of skill: InternalSkill) -> String {
        contents[skill.name] ?? skill.defaultContent
    }

    func save(_ content: String, of skill: InternalSkill) throws(StorageError) {
        if let failure { throw failure }
        contents[skill.name] = content
    }
}

/// System Prompts: the internal skills the app defines, and the content the user gives each
/// (docs/ui/system-prompts.md). A change is saved a second after the last keystroke, when another skill is
/// selected, and when the tab goes away.
@MainActor
@Observable
final class SystemPromptsModel {
    let skills: [InternalSkill]
    var selection: InternalSkill.ID?
    /// The contents as shown, by skill name.
    private(set) var contents: [String: String]
    /// The contents as stored.
    private var stored: [String: String]
    /// Why the last save failed, by skill name.
    private(set) var failures: [String: String] = [:]

    @ObservationIgnored private let store: any InternalSkillStore
    @ObservationIgnored private var pending: [String: Task<Void, Never>] = [:]
    /// How long after the last change a skill is saved.
    @ObservationIgnored let saveDelay: Duration

    init(skills: [InternalSkill] = InternalSkill.all, store: any InternalSkillStore, saveDelay: Duration = .seconds(1)) {
        self.skills = skills
        self.store = store
        self.saveDelay = saveDelay
        let contents = Dictionary(uniqueKeysWithValues: skills.map { ($0.name, store.content(of: $0)) })
        self.contents = contents
        stored = contents
        selection = skills.first?.id
    }

    var selected: InternalSkill? {
        skills.first { $0.id == selection }
    }

    func content(of skill: InternalSkill) -> String {
        contents[skill.name] ?? skill.defaultContent
    }

    /// Whether what shows is stored.
    func isSaved(_ skill: InternalSkill) -> Bool {
        contents[skill.name] == stored[skill.name]
    }

    /// The user's change: shown at once, saved after `saveDelay` without another change.
    func setContent(_ content: String, of skill: InternalSkill) {
        guard contents[skill.name] != content else { return }
        contents[skill.name] = content
        pending[skill.name]?.cancel()
        pending[skill.name] = Task { [weak self, saveDelay] in
            try? await Task.sleep(for: saveDelay)
            guard !Task.isCancelled else { return }
            self?.save(skill)
        }
    }

    /// Saves a skill now when it has a change.
    func save(_ skill: InternalSkill) {
        pending[skill.name]?.cancel()
        pending[skill.name] = nil
        guard let content = contents[skill.name], content != stored[skill.name] else { return }
        do throws(StorageError) {
            try store.save(content, of: skill)
            stored[skill.name] = content
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

/// System Prompts: the internal skills on the left, the selected one's name and content on the right. The app's
/// code defines the skills; the user edits their content (docs/ui/system-prompts.md).
public struct SystemPromptsView: View {
    @State private var model: SystemPromptsModel

    /// The skills of the app's data folder.
    public init(store: LiveInternalSkillStore) {
        _model = State(initialValue: SystemPromptsModel(store: store))
    }

    init(model: SystemPromptsModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
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
                    isSaved: model.isSaved(skill),
                    failure: model.failures[skill.name]
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
}

/// A skill's name, which the app defines, and its content, which the user writes.
private struct SkillEditor: View {
    let skill: InternalSkill
    @Binding var content: String
    let isSaved: Bool
    let failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent(String(localized: "Name", bundle: #bundle)) {
                Text(verbatim: skill.name)
                    .monospaced()
                    .textSelection(.enabled)
            }
            .help(String(localized: "The app defines this skill and its name.", bundle: #bundle))
            .accessibilityIdentifier("systemPrompts.name")

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

            status
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

#Preview("Empty", traits: .fixedLayout(width: 900, height: 560)) {
    SystemPromptsView(model: SystemPromptsModel(store: SampleInternalSkillStore()))
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
