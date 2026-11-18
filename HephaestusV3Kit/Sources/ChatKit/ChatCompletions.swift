import AZDesign
import ChatData
import Foundation

/// The skills the composer suggests after a `/` (docs/ui/chat.md › Skill completion), as V2's composer listed
/// them: the commands of the chat's CLI that are skills, matching what follows the `/`.
enum ChatCompletions {
    /// The most suggestions shown at once.
    static let limit = 20

    /// The suggestions for the composer's `text`: none unless it starts with `/` and holds no white space or
    /// line break. The skills (the commands not built into the CLI) whose name holds the typed text, in any
    /// case; those whose name, or its part after the last `:`, starts with it first, then the others, each
    /// group by name; at most `limit`. Picking one makes the text `/<name> `.
    static func list(for text: String, commands: [ClaudeCommand]) -> [MessageCompletion] {
        guard text.hasPrefix("/"), !text.contains(where: { $0.isWhitespace || $0.isNewline }) else { return [] }
        let typed = text.dropFirst().lowercased()
        let skills = commands.filter { !$0.isBuiltIn && (typed.isEmpty || $0.name.lowercased().contains(typed)) }
        func starts(_ command: ClaudeCommand) -> Bool {
            let name = command.name.lowercased()
            let last = name.split(separator: ":").last.map(String.init) ?? name
            return name.hasPrefix(typed) || last.hasPrefix(typed)
        }
        func byName(_ a: ClaudeCommand, _ b: ClaudeCommand) -> Bool {
            a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        let ordered = skills.filter(starts).sorted(by: byName) + skills.filter { !starts($0) }.sorted(by: byName)
        return ordered.prefix(limit).map { command in
            MessageCompletion(title: command.name, detail: command.description.isEmpty ? nil : command.description, text: "/\(command.name) ")
        }
    }
}
