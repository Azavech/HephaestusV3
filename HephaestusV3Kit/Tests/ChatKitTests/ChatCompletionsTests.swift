import ChatData
import Testing
@testable import ChatKit

/// docs/ui/chat.md › Skill completion.
@Suite("Skill completion")
struct ChatCompletionsTests {
    private let commands = [
        ClaudeCommand(name: "swift-testing", description: "Writes Swift Testing tests"),
        ClaudeCommand(name: "release-notes", description: "Writes the release notes\nof a version"),
        ClaudeCommand(name: "hephaestus-skills:report-feedback"),
        ClaudeCommand(name: "compact", description: "Free up context", isBuiltIn: true),
    ]

    private func names(_ text: String) -> [String] {
        ChatCompletions.list(for: text, commands: commands).map(\.title)
    }

    @Test("A lone / offers every skill by name; the CLI's own commands never")
    func all() {
        #expect(names("/") == ["hephaestus-skills:report-feedback", "release-notes", "swift-testing"])
    }

    @Test("Names that start with the typed text, or whose part after : does, come first; then those holding it")
    func order() {
        #expect(names("/re") == ["hephaestus-skills:report-feedback", "release-notes"])
        #expect(names("/t") == ["hephaestus-skills:report-feedback", "release-notes", "swift-testing"])
        #expect(names("/s") == ["swift-testing", "hephaestus-skills:report-feedback", "release-notes"])
        #expect(names("/REL") == ["release-notes"], "Any letter case")
    }

    @Test("Nothing without a first word that starts with / and holds no space, or without a match")
    func none() {
        #expect(names("").isEmpty && names("re").isEmpty && names("hello /re").isEmpty)
        #expect(names("/re x").isEmpty && names("/re\n").isEmpty && names("/zzz").isEmpty)
        #expect(names("/compact").isEmpty)
    }

    @Test("Picking one makes the text its call and a space; the detail is the description")
    func completion() throws {
        let first = try #require(ChatCompletions.list(for: "/rel", commands: commands).first)
        #expect(first.text == "/release-notes " && first.detail == "Writes the release notes\nof a version")
        #expect(ChatCompletions.list(for: "/rep", commands: commands).first?.detail == nil)
        let many = (1...30).map { ClaudeCommand(name: "skill-\($0)") }
        #expect(ChatCompletions.list(for: "/", commands: many).count == ChatCompletions.limit)
    }
}
