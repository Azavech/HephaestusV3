import FileStorage
import Foundation
import ProjectData
import Testing
@testable import ChatData

/// The internal skills the app defines, and their content in the data folder (docs/data.md › Internal skills).
@Suite("Internal skills")
struct InternalSkillTests {
    private func withFolder(_ body: (DataFolder) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("InternalSkillTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(DataFolder(url: url))
    }

    @Test("The app defines set-ticket-title, with V3's text, Haiku at a low effort, report-feedback, empty, resume-chat, with V3's text, both called from chats, and notification-summary, with V3's text, Haiku at a low effort; every name is in Claude's skill format, once")
    func definitions() {
        #expect(InternalSkill.all.map(\.name) == ["set-ticket-title", "report-feedback", "resume-chat", "notification-summary", "resume-agent",
                                                    "implement-ticket", "implement-bundle", "watch-ci", "comment-answer"])
        #expect(InternalSkill.watchCI.isCalledFromChats && InternalSkill.watchCI.command == "/hephaestus-skills:watch-ci")
        #expect(InternalSkill.watchCI.defaults.content.contains("\"CI passed.\", \"CI failed.\" or \"CI not checked.\""),
                "The first lines the app reads")
        #expect(InternalSkill.implementTicket.defaults.content.contains("watch_ci") && InternalSkill.implementBundle.defaults.content.contains("watch_ci"))
        #expect(InternalSkill.resumeAgent.isCalledFromChats && !InternalSkill.resumeAgent.defaults.content.isEmpty)
        #expect(!InternalSkill.notificationSummary.isCalledFromChats && !InternalSkill.notificationSummary.defaults.content.isEmpty)
        #expect(InternalSkill.notificationSummary.defaults.model == "haiku" && InternalSkill.notificationSummary.defaults.effort == .low)
        #expect(InternalSkill.resumeChat.isCalledFromChats && !InternalSkill.resumeChat.defaults.content.isEmpty)
        #expect(InternalSkill.resumeChat.command == "/hephaestus-skills:resume-chat")
        #expect(InternalSkill.setTicketTitle.defaults.model == "haiku" && InternalSkill.setTicketTitle.defaults.effort == .low)
        #expect(InternalSkill.setTicketTitle.defaults.content.contains("get_ticket")
                    && InternalSkill.setTicketTitle.defaults.content.contains("Answer with the title alone"))
        #expect(!InternalSkill.setTicketTitle.isCalledFromChats && InternalSkill.reportFeedback.isCalledFromChats)
        #expect(InternalSkill.reportFeedback.defaults == InternalSkillValues(content: "", model: "default", effort: .high))
        #expect(InternalSkill(name: "plain").defaults == InternalSkillValues(content: "", model: "default", effort: .high))
        #expect(InternalSkill.all.allSatisfy { InternalSkill.isValidName($0.name) })
        #expect(Set(InternalSkill.all.map(\.name)).count == InternalSkill.all.count)
    }

    @Test("Skill names: lowercase letters, digits and single hyphens inside, 1 to 64 characters")
    func names() {
        for name in ["a", "set-ticket-title", "v2-import", String(repeating: "a", count: 64)] {
            #expect(InternalSkill.isValidName(name), "\(name)")
        }
        for name in ["", "Set-Title", "set title", "-start", "end-", "two--hyphens", "été", "a_b", String(repeating: "a", count: 65)] {
            #expect(!InternalSkill.isValidName(name), "\(name)")
        }
    }

    @Test("A skill without a file has its defaults; a written one reads back as written, its content after the front matter")
    func roundTrip() throws {
        try withFolder { folder in
            let skill = InternalSkill.setTicketTitle
            #expect(folder.readSkill(skill) == skill.defaults)
            let values = InternalSkillValues(content: "Title it.\n\n---\nKeep the rule above.\n", model: "sonnet", effort: .medium)
            try folder.writeSkill(values, of: skill)
            let file = folder.skillFile(of: skill)
            #expect(file.path.hasSuffix("/skills/set-ticket-title/SKILL.md"))
            #expect(try String(contentsOf: file, encoding: .utf8)
                == "---\nname: set-ticket-title\nmodel: sonnet\neffort: medium\n---\nTitle it.\n\n---\nKeep the rule above.\n")
            #expect(folder.readSkill(skill) == values)
        }
    }

    @Test("An empty front matter reads as the defaults with the text after it, instead of crashing")
    func emptyFrontMatter() {
        let defaults = InternalSkill.resumeChat.defaults
        let values = DataFolder.values(of: "---\n---\nText", defaults: defaults)
        #expect(values.content == "Text" && values.model == defaults.model && values.effort == defaults.effort && values.otherLines.isEmpty)
        #expect(DataFolder.values(of: "---\n\n---\nText", defaults: defaults).content == "Text")
    }

    @Test("Front matter lines the app doesn't use are kept and written back after its keys; values it can't use leave the defaults")
    func otherLines() throws {
        try withFolder { folder in
            let skill = InternalSkill.setTicketTitle
            try FileManager.default.createDirectory(at: folder.skillFile(of: skill).deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("---\nname: renamed-by-hand\ndescription: Titles tickets.\nmodel:\neffort: extreme\n---\nBody".utf8).write(to: folder.skillFile(of: skill))
            var values = folder.readSkill(skill)
            #expect(values == InternalSkillValues(content: "Body", model: "haiku", effort: .low, otherLines: ["description: Titles tickets."]))
            values.model = "opus"
            try folder.writeSkill(values, of: skill)
            #expect(try String(contentsOf: folder.skillFile(of: skill), encoding: .utf8)
                == "---\nname: set-ticket-title\nmodel: opus\neffort: low\ndescription: Titles tickets.\n---\nBody")
        }
    }

    @Test("A file written by hand without front matter is all content, with the default model and effort")
    func handWritten() throws {
        try withFolder { folder in
            let skill = InternalSkill(name: "hand-written", defaultContent: "default")
            try FileManager.default.createDirectory(at: folder.skillFile(of: skill).deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("Just text.".utf8).write(to: folder.skillFile(of: skill))
            #expect(folder.readSkill(skill) == InternalSkillValues(content: "Just text.", model: "default", effort: .high))
        }
    }
}
