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
    /// A skill a chat calls, as `/hephaestus-skills:<name>` (V2's called skills): every chat's plugin has it. The
    /// app runs the others itself, and no chat sees them.
    public let isCalledFromChats: Bool

    public var id: String { name }

    public init(name: String, defaultContent: String = "", defaultModel: String = ChatSettings.defaultModel, defaultEffort: Effort = .high,
                isCalledFromChats: Bool = false) {
        self.name = name
        defaults = InternalSkillValues(content: defaultContent, model: defaultModel, effort: defaultEffort)
        self.isCalledFromChats = isCalledFromChats
    }

    /// Setting a ticket's title: the app runs it on each ticket created without a title, and for Generate Title.
    /// A short answer, so a quick model at a low effort.
    public static let setTicketTitle = InternalSkill(name: "set-ticket-title", defaultModel: "haiku", defaultEffort: .low)

    /// Turning feedback into a ticket: the first message of a feedback chat calls it.
    public static let reportFeedback = InternalSkill(name: "report-feedback", isCalledFromChats: true)

    /// Going on after a turn that ended with an error: the chat's Resume button calls it, where V2 sent a fixed
    /// message. Its default text is V3's own; the user edits it in System Prompts.
    public static let resumeChat = InternalSkill(name: "resume-chat", defaultContent: """
        Your last turn in this chat stopped with an error before it was finished. Look at what was already
        done, then finish what is left of the user's last request. Don't redo what is done.
        """, isCalledFromChats: true)

    /// Resume, on a sub-agent that failed or stopped: the chat's Claude resumes it with `SendMessage`. The message
    /// carries the agent's title and id after the call.
    public static let resumeAgent = InternalSkill(name: "resume-agent", defaultContent: """
        One of your agents in this chat stopped before it was finished. The arguments name it, with its agent id in
        parentheses. Resume that agent with SendMessage, telling it to go on from where it stopped.
        """, isCalledFromChats: true)

    /// The line of a chat's notification, as V2's `notification-summary`: the app runs it on what happened when
    /// Settings ▸ Notifications › AI-generated summary is on. A short answer, so a quick model at a low effort.
    public static let notificationSummary = InternalSkill(name: "notification-summary", defaultContent: """
        The message tells what just happened in a chat between the user and Claude: Claude's last reply, or what
        Claude waits for the user to answer. Write the line of a notification about it: one plain sentence of at
        most 150 characters that says what it is about. Answer with the sentence alone, without quotes or Markdown.
        """, defaultModel: "haiku", defaultEffort: .low)

    /// Every internal skill, in the order System Prompts lists them.
    public static let all: [InternalSkill] = [.setTicketTitle, .reportFeedback, .resumeChat, .notificationSummary, .resumeAgent]

    /// The plugin that gives chats the skills they call, as V2 named it.
    public static let pluginName = "hephaestus-skills"

    /// How a chat's message calls the skill: `/hephaestus-skills:report-feedback`.
    public var command: String { "/\(Self.pluginName):\(name)" }

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

    /// `Runtime/plugins/`: what every chat's CLI gets with `--plugin-dir`, which loads each plugin in it.
    public var pluginsFolder: URL { url.appendingPathComponent("Runtime/plugins", isDirectory: true) }

    /// Writes `Runtime/plugins/hephaestus-skills/` (docs/data.md › Chat plugin): its `.claude-plugin/plugin.json`,
    /// then `skills/<name>/SKILL.md` for each skill chats call, as the user last saved it, without the app's
    /// `model` and `effort` keys, so that the chat keeps its own; a folder of another name is removed. Returns
    /// the folder to give `--plugin-dir`.
    @discardableResult
    public func writeChatPlugin(_ skills: [InternalSkill] = InternalSkill.all) throws(StorageError) -> URL {
        let plugin = pluginsFolder.appendingPathComponent(InternalSkill.pluginName, isDirectory: true)
        let called = skills.filter(\.isCalledFromChats)
        let manifest = plugin.appendingPathComponent(".claude-plugin/plugin.json")
        let folder = plugin.appendingPathComponent("skills", isDirectory: true)
        func directory(_ url: URL) throws(StorageError) {
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                throw .writeFailed(path: url.path, reason: (error as NSError).localizedDescription)
            }
        }
        try directory(manifest.deletingLastPathComponent())
        let json = #"{"name":"\#(InternalSkill.pluginName)","version":"1.0.0"}"# + "\n"
        if (try? Data(contentsOf: manifest)) != Data(json.utf8) {
            try write(Data(json.utf8), to: manifest)
        }
        try directory(folder)
        let kept = Set(called.map(\.name))
        for entry in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where !kept.contains(entry) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(entry))
        }
        for skill in called {
            let values = readSkill(skill)
            let lines = ["name: \(skill.name)"] + values.otherLines
            let text = "---\n" + lines.joined(separator: "\n") + "\n---\n" + values.content
            let file = folder.appendingPathComponent(skill.name, isDirectory: true).appendingPathComponent("SKILL.md")
            try directory(file.deletingLastPathComponent())
            if (try? Data(contentsOf: file)) != Data(text.utf8) {
                try write(Data(text.utf8), to: file)
            }
        }
        return pluginsFolder
    }

    private func write(_ data: Data, to file: URL) throws(StorageError) {
        do {
            _ = try AtomicFile.write(data, to: file)
        } catch let error as StorageError {
            throw error
        } catch {
            throw .writeFailed(path: file.path, reason: String(describing: error))
        }
    }

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
