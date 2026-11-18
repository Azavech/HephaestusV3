import ChatData
import FileStorage
import Testing
@testable import ChatKit

/// System Prompts: the internal skills' content, shown at once and saved after a pause (docs/ui/system-prompts.md).
@MainActor
@Suite("System Prompts")
struct SystemPromptsTests {
    private let skill = InternalSkill.setTicketTitle

    @Test("It lists the app's skills, the first selected, with their stored content")
    func opening() {
        let model = SystemPromptsModel(store: SampleInternalSkillStore(contents: ["set-ticket-title": "Stored"]))
        #expect(model.skills.map(\.name) == ["set-ticket-title", "report-feedback", "resume-chat", "notification-summary"])
        #expect(model.selected == skill)
        #expect(model.content(of: skill) == "Stored")
        #expect(model.isSaved(skill))
    }

    @Test("A change shows at once and is saved after the delay; a save writes only a change")
    func delayedSave() async throws {
        let store = SampleInternalSkillStore()
        let model = SystemPromptsModel(store: store, saveDelay: .milliseconds(20))
        model.setContent("Title it.", of: skill)
        #expect(model.content(of: skill) == "Title it.")
        #expect(!model.isSaved(skill))
        #expect(store.saved["set-ticket-title"] == nil)
        try await Task.sleep(for: .milliseconds(200))
        #expect(store.saved["set-ticket-title"]?.content == "Title it.")
        #expect(model.isSaved(skill))
    }

    @Test("Save All writes every change at once, as selecting another skill or leaving does")
    func saveAll() {
        let store = SampleInternalSkillStore()
        let model = SystemPromptsModel(store: store, saveDelay: .seconds(60))
        model.setContent("Now.", of: skill)
        model.saveAll()
        #expect(store.saved["set-ticket-title"]?.content == "Now.")
        #expect(model.isSaved(skill))
    }

    @Test("The model and the effort are saved at once, with the content as shown")
    func modelAndEffort() {
        let store = SampleInternalSkillStore()
        let model = SystemPromptsModel(store: store, saveDelay: .seconds(60))
        #expect(model.values(of: skill).model == "haiku")
        model.setContent("Typed.", of: skill)
        model.setModel("sonnet", of: skill)
        #expect(store.saved["set-ticket-title"] == InternalSkillValues(content: "Typed.", model: "sonnet", effort: .low))
        model.setEffort(.high, of: skill)
        #expect(store.saved["set-ticket-title"]?.effort == .high)
        #expect(model.isSaved(skill))
    }

    @Test("A failed save keeps the text and says why; the next one that works clears it")
    func failure() {
        let store = SampleInternalSkillStore(failure: .writeFailed(path: "skills/set-ticket-title/SKILL.md", reason: "Permission denied"))
        let model = SystemPromptsModel(store: store, saveDelay: .seconds(60))
        model.setContent("Kept.", of: skill)
        model.save(skill)
        #expect(model.failures["set-ticket-title"] != nil)
        #expect(model.content(of: skill) == "Kept.")
        #expect(!model.isSaved(skill))
        store.failure = nil
        model.save(skill)
        #expect(model.failures["set-ticket-title"] == nil)
        #expect(store.saved["set-ticket-title"]?.content == "Kept.")
    }
}
