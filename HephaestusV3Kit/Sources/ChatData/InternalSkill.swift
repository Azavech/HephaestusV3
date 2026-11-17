import FileStorage
import Foundation
import ProjectData

/// A skill the app defines for Claude itself, whose content the user edits in System Prompts
/// (docs/data.md › Internal skills). The app's code holds the list and each skill's name: the user doesn't
/// add, rename or remove them.
public struct InternalSkill: Hashable, Sendable, Identifiable {
    /// In Claude's skill name format: lowercase letters, digits and hyphens, 1 to 64 characters.
    public let name: String
    /// The content until the user edits it.
    public let defaultContent: String

    public var id: String { name }

    public init(name: String, defaultContent: String = "") {
        self.name = name
        self.defaultContent = defaultContent
    }

    /// Setting a ticket's title from its description. Empty, and used by nothing yet.
    public static let setTicketTitle = InternalSkill(name: "set-ticket-title")

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

extension DataFolder {
    /// `skills/`: the internal skills, one folder each, as Claude's skills are laid out.
    public var skillsFolder: URL { url.appendingPathComponent("skills", isDirectory: true) }

    /// `skills/<name>/SKILL.md`.
    public func skillFile(of skill: InternalSkill) -> URL {
        skillsFolder.appendingPathComponent(skill.name, isDirectory: true).appendingPathComponent("SKILL.md")
    }

    /// A skill's content: the body of its `SKILL.md`, after the front matter; its default content while the file
    /// doesn't exist or can't be read.
    public func readContent(of skill: InternalSkill) -> String {
        guard let data = try? Data(contentsOf: skillFile(of: skill)), let text = String(data: data, encoding: .utf8) else {
            return skill.defaultContent
        }
        return Self.body(of: text)
    }

    /// Writes a skill's `SKILL.md`: front matter with its name, then the content as it is. Atomic; the folder is
    /// made when missing.
    public func writeContent(_ content: String, of skill: InternalSkill) throws(StorageError) {
        let file = skillFile(of: skill)
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw .writeFailed(path: file.deletingLastPathComponent().path, reason: (error as NSError).localizedDescription)
        }
        do {
            _ = try AtomicFile.write(Data(Self.skillFile(name: skill.name, content: content).utf8), to: file)
        } catch let error as StorageError {
            throw error
        } catch {
            throw .writeFailed(path: file.path, reason: String(describing: error))
        }
    }

    /// A `SKILL.md`'s text: `---`, `name: <name>`, `---`, then the content.
    static func skillFile(name: String, content: String) -> String {
        "---\nname: \(name)\n---\n\(content)"
    }

    /// A `SKILL.md`'s body: what follows the front matter's closing `---` line; the whole text without front
    /// matter.
    static func body(of text: String) -> String {
        guard text.hasPrefix("---\n"), let close = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) else {
            return text
        }
        return String(text[close.upperBound...])
    }
}
