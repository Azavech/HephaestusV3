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

    @Test("The app defines set-ticket-title, empty; every name is in Claude's skill format, once")
    func definitions() {
        #expect(InternalSkill.all.map(\.name) == ["set-ticket-title"])
        #expect(InternalSkill.setTicketTitle.defaultContent.isEmpty)
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

    @Test("A skill without a file has its default content; a written one reads back as written, after its front matter")
    func roundTrip() throws {
        try withFolder { folder in
            let skill = InternalSkill.setTicketTitle
            #expect(folder.readContent(of: skill) == "")
            try folder.writeContent("Title it.\n\n---\nKeep the rule above.\n", of: skill)
            let file = folder.skillFile(of: skill)
            #expect(file.path.hasSuffix("/skills/set-ticket-title/SKILL.md"))
            #expect(try String(contentsOf: file, encoding: .utf8) == "---\nname: set-ticket-title\n---\nTitle it.\n\n---\nKeep the rule above.\n")
            #expect(folder.readContent(of: skill) == "Title it.\n\n---\nKeep the rule above.\n")
            try folder.writeContent("", of: skill)
            #expect(folder.readContent(of: skill) == "")
        }
    }

    @Test("A file written by hand without front matter is all content")
    func handWritten() throws {
        try withFolder { folder in
            let skill = InternalSkill(name: "hand-written", defaultContent: "default")
            try FileManager.default.createDirectory(at: folder.skillFile(of: skill).deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("Just text.".utf8).write(to: folder.skillFile(of: skill))
            #expect(folder.readContent(of: skill) == "Just text.")
        }
    }
}
