import FileStorage
import Foundation
import ProjectData

/// A skill the app defines for Claude itself, whose content, model and effort the user edits in System Prompts
/// (docs/data.md › Internal skills). The app's code holds the list, each skill's name and its defaults: the
/// user doesn't add, rename or remove them.
public struct InternalSkill: Hashable, Sendable, Identifiable {
    /// In Claude's skill name format: lowercase letters, digits and hyphens, 1 to 64 characters.
    public let name: String
    /// The content, model and effort until the user changes them.
    public let defaults: InternalSkillValues

    public var id: String { name }

    public init(name: String, defaultContent: String = "", defaultModel: String = ChatSettings.defaultModel, defaultEffort: Effort = .high) {
        self.name = name
        defaults = InternalSkillValues(content: defaultContent, model: defaultModel, effort: defaultEffort)
    }

    /// Setting a ticket's title from its description: empty, and used by nothing yet. A short answer, so a quick
    /// model at a low effort.
    public static let setTicketTitle = InternalSkill(name: "set-ticket-title", defaultModel: "haiku", defaultEffort: .low)

    /// Every internal skill, in the order System Prompts lists them.
    public static let all: [InternalSkill] = [.setTicketTitle]

    /// Claude's skill name format: 1 to 64 characters, lowercase ASCII letters, digits and hyphens, not starting
    /// or ending with a hyphen, without two hyphens in a row.
    public static func isValidName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard (1...64).contains(bytes.count), bytes.first != UInt8(ascii: "-"), bytes.last != UInt8(ascii: "-"),
              !name.contains("--") else { return false }
        return bytes.allSatisfy { (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == UInt8(ascii: "-") }
    }
}

/// What the user sets for an internal skill. The model and effort are those the app uses when it runs the skill
/// itself; a chat that calls the skill keeps its own.
public struct InternalSkillValues: Hashable, Sendable {
    public var content: String
    /// What `--model` takes: `default`, `haiku`, `opus`, or a model id.
    public var model: String
    public var effort: Effort
    /// The front matter's other lines, kept as written and written back after the app's keys.
    public var otherLines: [String]

    public init(content: String, model: String, effort: Effort, otherLines: [String] = []) {
        self.content = content
        self.model = model
        self.effort = effort
        self.otherLines = otherLines
    }
}

extension DataFolder {
    /// `skills/`: the internal skills, one folder each, as Claude's skills are laid out.
    public var skillsFolder: URL { url.appendingPathComponent("skills", isDirectory: true) }

    /// `skills/<name>/SKILL.md`.
    public func skillFile(of skill: InternalSkill) -> URL {
        skillsFolder.appendingPathComponent(skill.name, isDirectory: true).appendingPathComponent("SKILL.md")
    }

    /// A skill's values from its `SKILL.md`: the front matter's `model` and `effort`, the body as content; the
    /// skill's defaults for what the file doesn't have, and for all of it while the file doesn't exist or can't be
    /// read.
    public func readSkill(_ skill: InternalSkill) -> InternalSkillValues {
        guard let data = try? Data(contentsOf: skillFile(of: skill)), let text = String(data: data, encoding: .utf8) else {
            return skill.defaults
        }
        return Self.values(of: text, defaults: skill.defaults)
    }

    /// Writes a skill's `SKILL.md`: the front matter (`name`, `model`, `effort`, then the other lines kept), then
    /// the content as it is. Atomic; the folder is made when missing.
    public func writeSkill(_ values: InternalSkillValues, of skill: InternalSkill) throws(StorageError) {
        let file = skillFile(of: skill)
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw .writeFailed(path: file.deletingLastPathComponent().path, reason: (error as NSError).localizedDescription)
        }
        do {
            _ = try AtomicFile.write(Data(Self.skillFile(name: skill.name, values: values).utf8), to: file)
        } catch let error as StorageError {
            throw error
        } catch {
            throw .writeFailed(path: file.path, reason: String(describing: error))
        }
    }

    /// A `SKILL.md`'s text.
    static func skillFile(name: String, values: InternalSkillValues) -> String {
        let lines = ["name: \(name)", "model: \(values.model)", "effort: \(values.effort.rawValue)"] + values.otherLines
        return "---\n" + lines.joined(separator: "\n") + "\n---\n" + values.content
    }

    /// The values of a `SKILL.md`'s text. Its front matter is the lines between a first `---` line and the next
    /// one; each `key: value` line of the app's keys sets that value (`name` is the code's), any other line is
    /// kept. A text without front matter is all content.
    static func values(of text: String, defaults: InternalSkillValues) -> InternalSkillValues {
        var values = defaults
        values.otherLines = []
        guard text.hasPrefix("---\n"), let close = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) else {
            values.content = text
            return values
        }
        values.content = String(text[close.upperBound...])
        let frontMatter = text[text.index(text.startIndex, offsetBy: 4)..<close.lowerBound]
        for line in frontMatter.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            // The app's keys are always taken, so they are never written twice; a value they can't use leaves
            // the default.
            switch parts.first {
            case "name":
                continue
            case "model":
                if parts.count == 2, !parts[1].isEmpty {
                    values.model = parts[1]
                }
            case "effort":
                if parts.count == 2, let effort = Effort(rawValue: parts[1]) {
                    values.effort = effort
                }
            default:
                values.otherLines.append(line)
            }
        }
        return values
    }
}
