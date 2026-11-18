import Foundation
import MCPKit

/// Whether a chat's Claude may edit the project's files, as Settings ▸ Chat › Edit the project's files says
/// (docs/ui/chat.md › Files).
public enum ChatFileEdits: String, Sendable, Hashable, CaseIterable {
    /// The CLI gets no editing tool; a request from a process started before the change is refused.
    case never
    /// Each edit waits for the user's answer to a card.
    case askFirst
    /// An edit inside the project's folder runs without asking, except in `.hephaestus/`.
    case always
}

/// The Claude CLI's own tools a chat gets besides the app's MCP tools, every one as in V2 (shell, web, agents,
/// workflows, files), and what the app answers when the CLI asks before a call of a file tool (docs/data.md ›
/// Chat processes › The CLI's tools).
public enum ClaudeFileTools {
    /// The tools that read files: always given.
    public static let reading = ["Read", "Grep", "Glob"]
    /// The tools that edit files: taken away when the user set Never.
    public static let editing = ["Edit", "Write", "NotebookEdit"]
    /// The CLI's question tool, which the app's `ask_questions` replaces, as V2 did.
    public static let question = "AskUserQuestion"

    /// The value of `--disallowedTools`: the CLI's question tool, and the editing tools when `edits` is Never.
    /// Every other tool of the CLI stays, its calls asking as the chat's permission mode says.
    public static func disallowed(edits: ChatFileEdits) -> [String] {
        edits == .never ? [question] + editing : [question]
    }

    /// The app's answer to the CLI's `can_use_tool` request for a file tool.
    public enum Decision: Sendable, Hashable {
        /// Allowed at once, without a card.
        case allow
        /// A card asks the user.
        case ask
        /// Refused at once with this message, which Claude reads.
        case deny(String)
    }

    /// The refusal of an edit when the user set Never.
    public static let editRefusal = "The user doesn't let Claude edit files from chats (Settings ▸ Chat)."

    /// What the app answers for `tool` with `input` in a chat whose project's folder is `root`; nil for a tool
    /// that isn't a file tool, which keeps its card. A read inside the folder runs; outside, it asks. An edit is
    /// refused under Never; under Always it runs inside the folder, but not in its `.hephaestus/` folder, whose
    /// files the app's tools change; anything else asks.
    public static func decision(tool: String, input: JSONValue, root: String, edits: ChatFileEdits) -> Decision? {
        let isEdit = editing.contains(tool)
        guard isEdit || reading.contains(tool) else { return nil }
        let place = path(tool: tool, input: input, root: root).map { location($0, in: root) } ?? .outside
        if isEdit {
            switch edits {
            case .never: return .deny(editRefusal)
            case .askFirst: return .ask
            case .always: return place == .inside ? .allow : .ask
            }
        }
        return place == .outside ? .ask : .allow
    }

    /// The absolute path a file tool's call reads or edits: `file_path`, or the `path` of `Grep` and `Glob`,
    /// the project's folder when it has none. A relative path is taken from the project's folder.
    public static func path(tool: String, input: JSONValue, root: String) -> String? {
        let given: String?
        switch tool {
        case "Read", "Edit", "Write": given = input["file_path"]?.stringValue
        case "NotebookEdit": given = input["notebook_path"]?.stringValue
        case "Grep", "Glob": given = input["path"]?.stringValue ?? root
        default: return nil
        }
        guard let given, !given.isEmpty else { return nil }
        let expanded = (given as NSString).expandingTildeInPath
        let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : URL(fileURLWithPath: root).appendingPathComponent(expanded)
        return url.standardizedFileURL.path
    }

    /// Where a path is: in the project's folder, in its `.hephaestus/` folder, or outside it. Symbolic links
    /// are resolved, those of a part that doesn't exist yet aside.
    public enum Location: Sendable, Hashable {
        case inside
        case appData
        case outside
    }

    public static func location(_ path: String, in root: String) -> Location {
        let folder = resolved(root)
        let target = resolved(path)
        guard target == folder || target.hasPrefix(folder + "/") else { return .outside }
        let data = folder + "/.hephaestus"
        return target == data || target.hasPrefix(data + "/") ? .appData : .inside
    }

    /// `path` with the symbolic links of its longest existing part resolved.
    static func resolved(_ path: String) -> String {
        var existing = URL(fileURLWithPath: path).standardizedFileURL
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            rest.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var url = existing.resolvingSymlinksInPath()
        for part in rest {
            url.appendPathComponent(part)
        }
        return url.standardizedFileURL.path
    }
}
