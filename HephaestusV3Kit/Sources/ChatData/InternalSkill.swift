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
    /// A short answer, so a quick model at a low effort. Its default text is V3's own, so that titles name the
    /// ticket's subject before the user writes one (HEPH-9).
    public static let setTicketTitle = InternalSkill(name: "set-ticket-title", defaultContent: """
        Give a ticket its title. The message links the ticket (its Attached: line), holds a description, or both: \
        read a linked ticket with get_ticket; a description in the message is newer than the ticket's and replaces it.
        The title names what the ticket asks for or reports, in at most 80 characters, such as "Line up the New \
        Bundle + with the sidebar rows". Leave out the ticket's id, status, author and dates.
        Answer with the title alone, on one line, without quotes, Markdown or a final period.
        """, defaultModel: "haiku", defaultEffort: .low)

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

    /// Implementing a ticket, as V2's skill of the same name: Implement's first message calls it with the ticket's
    /// id, and a bundle's chat's `implement_ticket` with the bundle's after it (docs/data.md › Implement chats). Its
    /// default text is V3's own.
    public static let implementTicket = InternalSkill(name: "implement-ticket", defaultContent: """
        Implement the ticket the arguments name. When a second id follows it, a bundle's, that bundle's chat \
        started you: you work in a git worktree, on your own branch.

        1. Read the ticket with get_ticket, and its files with get_attachment. Set its status to in_progress with \
        set_ticket_status.
        2. Make the change the ticket asks for: the project's docs first when it keeps a specification, then the \
        code. Build it and run its tests until they pass.
        3. Commit the change. When a bundle's chat started you, commit on your branch, don't push or merge, and \
        skip step 5: that chat merges the branches, pushes and follows the CI. Otherwise, push the commit.
        4. Comment on the ticket with add_comment: what changed, the commit, the tests you ran and their results, \
        and each choice you made where the ticket left one open.
        5. When you pushed and the project has a GitHub page (githubPage in get_project), follow the CI of the \
        pushed commit as below before you go on.
        6. Set the status to review.
        7. Close the CI chats you started with close_chat, then reply with what changed, the commit, the tests and \
        how the CI went.

        Until the user writes in this chat, ask no questions: decide what the ticket leaves open, and list those \
        decisions in your comment.

        Following the CI:
        - Call watch_ci with the full hash of the pushed commit, then end your turn. The app starts a CI chat that \
        watches the commit's workflow runs, and sends you its report when its turn ends: "CI chat finished its \
        turn:" with its reply, whose first line is "CI passed.", "CI failed." or "CI not checked.", or "CI chat \
        ended in error: <reason>", or "CI chat was stopped.".
        - Until that report, don't set the status and don't close this chat.
        - After "CI passed." or "CI not checked.", go on. When the CI wasn't checked, say why in your reply.
        - After "CI failed.", an error or a stop, ask the user how to go on with ask_questions, even when they \
        haven't written in this chat yet: the app lets you post this one question set. Offer these answers:
          - Fix and check again: fix the cause, build and test, commit the fix and push it, add it to your comment \
        with update_comment, then call watch_ci with the new commit.
          - Re-run the failed runs: re-run each failed run with rerun_run and failedOnly, then call watch_ci with \
        the same commit. If the app refuses rerun_run, say so in your reply and stop there.
          - Finish without green CI: name the failed runs in your comment with update_comment, then go on.
        - When the push or watch_ci fails, don't wait: say in your comment and your reply that the CI wasn't \
        followed, and why.
        """, isCalledFromChats: true)

    /// Implementing a bundle by running one chat per ticket, as V2's skill of the same name: Implement All's first
    /// message calls it with the bundle's id. Its default text is V3's own, and says how to use `implement_ticket`
    /// and the app's reports.
    public static let implementBundle = InternalSkill(name: "implement-bundle", defaultContent: """
        Implement the bundle the arguments name, by running one chat per ticket.

        1. Read the bundle with get_bundle and each of its tickets with get_ticket. Leave out the tickets that are \
        done.
        2. Start a chat for each ticket that waits for no other ticket, with implement_ticket. A ticket waits for \
        the tickets of the bundle it depends on that aren't done. Each chat works on its own branch, <bundle \
        id>/<ticket id>, in a git worktree the app makes from the current commit, and commits there.
        3. The app sends you a message each time one of these chats ends a turn: "Chat of <ticket id> finished its \
        turn:" with its last reply, "Chat of <ticket id> ended in error: <reason>", or "Chat of <ticket id> was \
        stopped.". Once every ticket a waiting ticket depends on has reported, merge their branches into the \
        project's current branch, then start the waiting ticket's chat.
        4. After an error or a stop, ask the user with ask_questions whether to retry the ticket on a fresh branch \
        (implement_ticket again), skip it with the tickets that depend on it, or stop. The other chats keep running.
        5. Once every ticket has reported or was skipped, merge the remaining branches into the current branch in \
        the bundle's order, one commit per ticket, resolving the conflicts. Build and run the tests once on the \
        result; when they fail, fix them or ask the user.
        6. Update each ticket's comment with its commit on the current branch, then remove the merged worktrees and \
        branches (git worktree remove, git branch -d).
        7. Push the current branch. When the project has a GitHub page (githubPage in get_project), follow the CI \
        of the pushed commit as below.
        8. Close the chats you started with close_chat, the CI chats too, then reply with each ticket and its \
        commit, or why it was skipped, the conflicts you resolved, and how the CI went.

        Following the CI:
        - Call watch_ci with the full hash of the pushed commit, then end your turn. The app starts a CI chat that \
        watches the commit's workflow runs, and sends you its report when its turn ends: "CI chat finished its \
        turn:" with its reply, whose first line is "CI passed.", "CI failed." or "CI not checked.", or "CI chat \
        ended in error: <reason>", or "CI chat was stopped.".
        - After "CI passed." or "CI not checked.", go on. When the CI wasn't checked, say why in your reply.
        - After "CI failed.", an error or a stop, ask the user how to go on with ask_questions. Offer these answers:
          - Fix and check again: fix the cause yourself, build and test, commit the fix naming the ticket whose \
        change caused it, push it, add it to that ticket's comment with update_comment, then call watch_ci with the \
        new commit.
          - Re-run the failed runs: re-run each failed run with rerun_run and failedOnly, then call watch_ci with \
        the same commit. If the app refuses rerun_run, say so in your reply and stop there.
          - Finish without green CI: name the failed runs in the tickets' comments with update_comment, then go on.
        - When the push or watch_ci fails, don't wait: say in your reply that the CI wasn't followed, and why.
        """, isCalledFromChats: true)

    /// Following the CI of a pushed commit, as V2's CI chats: the first message of the chat `watch_ci` starts calls it
    /// with the commit, the project attached (docs/data.md › CI chats). Its default text is V3's own, and says which
    /// first line the app reads to tell a failure.
    public static let watchCI = InternalSkill(name: "watch-ci", defaultContent: """
        Follow the GitHub Actions runs of the commit the arguments name, then report on them. The chat that pushed \
        the commit started this one, and the app sends it your last reply when your turn ends: that chat decides \
        what to do next.

        1. Read the project the message attaches with get_project: its githubPage, \
        https://github.com/<owner>/<name>, is the repository.
        2. List the commit's workflow runs with the gh CLI in your shell: gh run list --repo <owner>/<name> \
        --commit <commit> --json databaseId,workflowName,status,conclusion. Runs can take a minute to show after a \
        push: look again for two minutes before you decide there are none.
        3. Wait for each run to end, in the foreground: gh run watch <run id> --repo <owner>/<name> --exit-status. \
        When the shell moves a command that runs too long to the background, stop that task and watch again. Once \
        every run has ended, list the runs again, in case a new one started.
        4. End your turn with a reply whose first line is "CI passed.", "CI failed." or "CI not checked.", with \
        nothing else on that line:
           - "CI passed." when every run succeeded.
           - "CI failed." when a run failed or was cancelled. Under it, for each such run: its workflow, its id, \
        its failed jobs, and the cause, read with gh run view <run id> --repo <owner>/<name> --log-failed.
           - "CI not checked." when you couldn't follow the runs. Under it, why: the commit has no workflow run, gh \
        is missing or not logged in, or the project has no GitHub page.

        Change no file, make no commit and ask no questions. Keep this turn going until you can reply: the app \
        reports to the other chat as soon as it ends.
        """, isCalledFromChats: true)

    /// Every internal skill, in the order System Prompts lists them.
    /// Answering a ticket comment that mentions Claude, as V2's `comment-answer`: the app runs it on each new comment
    /// of the user that mentions `@Claude`, in the project's folder, and posts the answer as Claude's comment.
    public static let commentAnswer = InternalSkill(name: "comment-answer", defaultContent: """
        You are Claude, inside Hephaestus V3, a macOS app that coordinates the work on many projects. The user mentioned \
        you in a comment of a ticket. The message gives the project, the ticket and the comment to answer, and links the \
        ticket (its Attached: line): read it with get_ticket. Your working directory is the project's folder.
        Your reply is posted as a new comment by Claude at the end of the ticket's comments: write it for the user who \
        wrote the comment, in Markdown and in the language of the comment. Answer the comment, and do what it asks when \
        these rules allow it.

        What you may do:
        - Read the project's docs and code with Read, Grep and Glob, and the attachments of the ticket and of its comments.
        - Read the app's data with the hephaestus tools that read.
        - When the comment asks for it, change this ticket: its title and description with update_ticket, its links with \
        the links of update_ticket (list every link to keep), its status with set_ticket_status.
        - Change nothing else: no docs, no code, no other file, ticket, comment or attachment. When the comment asks for \
        such work, say that it needs a chat of the ticket, which the user starts with Implement or from the ticket's Chats.

        Rules:
        - Never invent a requirement, a behavior, a name or a value shown to users, a file format or a product decision: \
        take them from the comment, the ticket with its comments and attachments, the docs or the code. Look there \
        before you ask.
        - Ask only true unknowns, in your reply: the user answers with a new comment that mentions you.
        - Change a status only when the comment asks for it, and never the status of a done ticket: tell the user to do it.
        - When the app answers forbidden or invalid, report its message in your reply and don't work around it.
        - Report only what you did and checked, and name every change you made to the ticket.
        """)

    /// The memories every chat gets, as V2's common skill gave them (docs/data.md › Memories › In chats): appended to
    /// the CLI's system prompt at each launch, its placeholders filled with the global memories folder and its
    /// `MEMORY.md`, and the memories the project inherits from its parents. Blank, nothing is appended.
    public static let chatMemories = InternalSkill(name: "chat-memories", defaultContent: """
        # Global memories

        Besides the memory folder of this project, which the Claude CLI gives you, you have global memories: memories \
        that hold for every project, which every chat of every project receives. Their folder is \
        {{globalMemoriesFolder}}. Its files have the format of your project memories: one .md file per memory, with \
        name, description and metadata.type in its front matter, and one line per memory in the folder's MEMORY.md. The \
        global MEMORY.md follows, empty while it has no line:

        {{globalMemories}}

        Decide per memory where you save it: a memory that holds for every project goes to the global memories folder, \
        with its line in the global MEMORY.md; the other memories go to the project's memory folder. When a line of the \
        global MEMORY.md concerns your work, read that memory's file.

        # Memories of the parent projects

        When this project is a sub project, the memories Claude saved for its parent projects follow, nearest parent \
        first: each parent's name, identifier and memory folder, then its MEMORY.md. Nothing follows for a top-level \
        project. Read a memory file of these folders with your file tools when it is relevant, as you read your own \
        memories. Never write in these folders: save every new memory in your own memory folder or, when it holds for \
        every project, in the global memories folder.

        {{parentMemories}}
        """)

    public static let all: [InternalSkill] = [.setTicketTitle, .reportFeedback, .resumeChat, .notificationSummary, .resumeAgent,
                                              .implementTicket, .implementBundle, .watchCI, .commentAnswer, .chatMemories]

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
        // An empty front matter (`---` right after `---`) closes before its first line could start.
        let start = text.index(text.startIndex, offsetBy: 4)
        guard close.lowerBound > start else { return values }
        let frontMatter = text[start..<close.lowerBound]
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
