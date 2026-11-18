import ChatData
import Foundation
import MCPKit

/// How a chat words a call of the Claude CLI's file tools, and the card of one the app asks about (docs/ui/chat.md ›
/// Files). A path inside the project's folder is shown relative to it, another one whole.
enum FileToolText {
    /// The row of a call: what it did, and the path it worked on as its detail (a search shows its result's
    /// first line instead). Nil for a tool that isn't a file tool.
    static func call(_ name: String, input: JSONValue, root: String?) -> ChatToolCall? {
        guard ClaudeFileTools.reading.contains(name) || ClaudeFileTools.editing.contains(name) else { return nil }
        let path = root.flatMap { ClaudeFileTools.path(tool: name, input: input, root: $0) }
        let shown = path.map { display($0, root: root) } ?? input["file_path"]?.stringValue ?? ""
        let pattern = input["pattern"]?.stringValue ?? ""
        let folder = input["path"]?.stringValue == nil ? nil : shown
        let action: String
        var detail = path
        switch name {
        case "Read":
            action = String(localized: "Read \(shown)", bundle: #bundle, comment: "A chat's call: Claude read a file")
        case "Edit":
            action = String(localized: "Edited \(shown)", bundle: #bundle, comment: "A chat's call: Claude edited a file")
        case "Write":
            action = String(localized: "Wrote \(shown)", bundle: #bundle, comment: "A chat's call: Claude wrote a whole file")
        case "NotebookEdit":
            action = String(localized: "Edited \(input["notebook_path"]?.stringValue.map { display($0, root: root) } ?? shown)", bundle: #bundle,
                            comment: "A chat's call: Claude edited a file")
        case "Grep":
            action = folder.map { String(localized: "Searched for “\(pattern)” in \($0)", bundle: #bundle, comment: "A chat's call: Claude searched files in a folder") }
                ?? String(localized: "Searched for “\(pattern)”", bundle: #bundle, comment: "A chat's call: Claude searched the project's files")
            detail = nil
        default:
            action = folder.map { String(localized: "Listed the files matching \(pattern) in \($0)", bundle: #bundle, comment: "A chat's call: Claude listed files in a folder") }
                ?? String(localized: "Listed the files matching \(pattern)", bundle: #bundle, comment: "A chat's call: Claude listed the project's files")
        }
        var call = ChatToolCall(action: action, reference: nil)
        call.detail = detail
        return call
    }

    /// The card's title and preview for the CLI's request about a file tool; nil for another tool. An edit shows
    /// the text it replaces, each line after `- `, then the new text, each line after `+ `; a whole file, its
    /// content.
    static func request(_ name: String, input: JSONValue, root: String?) -> (request: String, preview: String?)? {
        guard ClaudeFileTools.reading.contains(name) || ClaudeFileTools.editing.contains(name) else { return nil }
        let path = root.flatMap { ClaudeFileTools.path(tool: name, input: input, root: $0) }
        let shown = path.map { display($0, root: root) } ?? input["file_path"]?.stringValue ?? input["path"]?.stringValue ?? ""
        switch name {
        case "Read":
            return (String(localized: "Claude wants to read \(shown)", bundle: #bundle), nil)
        case "Grep":
            return (String(localized: "Claude wants to search \(shown)", bundle: #bundle), input["pattern"]?.stringValue)
        case "Glob":
            return (String(localized: "Claude wants to list the files in \(shown)", bundle: #bundle), input["pattern"]?.stringValue)
        case "NotebookEdit":
            let notebook = input["notebook_path"]?.stringValue.map { display($0, root: root) } ?? shown
            return (String(localized: "Claude wants to edit \(notebook)", bundle: #bundle), input["new_source"]?.stringValue)
        case "Edit":
            let old = prefixed(input["old_string"]?.stringValue ?? "", "- ")
            let new = prefixed(input["new_string"]?.stringValue ?? "", "+ ")
            return (String(localized: "Claude wants to edit \(shown)", bundle: #bundle), old + "\n" + new)
        default:
            return (String(localized: "Claude wants to write \(shown)", bundle: #bundle), input["content"]?.stringValue)
        }
    }

    /// The path relative to the project's folder when it is inside it; whole otherwise.
    static func display(_ path: String, root: String?) -> String {
        guard let root else { return path }
        let folder = URL(fileURLWithPath: root).standardizedFileURL.path
        if path == folder { return "." }
        return path.hasPrefix(folder + "/") ? String(path.dropFirst(folder.count + 1)) : path
    }

    private static func prefixed(_ text: String, _ prefix: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { prefix + $0 }.joined(separator: "\n")
    }
}

/// How a chat words a call of the Claude CLI's other tools, V2's shell, web, agent and workflow tools
/// (docs/ui/chat.md › Tool-call rows), and the title of the card of one: the action, and the command, address or
/// query as its detail. A tool without wording of its own reads "Used <name>".
enum CLIToolText {
    static func call(_ name: String, input: JSONValue) -> ChatToolCall? {
        let description = input["description"]?.stringValue
        let action: String
        var detail: String?
        switch name {
        case "Bash":
            let command = input["command"]?.stringValue ?? ""
            let first = command.split(whereSeparator: \.isNewline).first.map(String.init) ?? command
            action = input["run_in_background"]?.boolValue == true
                ? String(localized: "Started in the background: \(description ?? first)", bundle: #bundle, comment: "A chat's call: Claude started a command that keeps running")
                : String(localized: "Ran \(description ?? first)", bundle: #bundle, comment: "A chat's call: Claude ran a shell command")
            detail = command
        case "BashOutput", "TaskOutput":
            action = String(localized: "Read a background command's output", bundle: #bundle, comment: "A chat's call")
        case "KillShell", "KillBash", "TaskStop":
            action = String(localized: "Stopped a background task", bundle: #bundle, comment: "A chat's call")
        case "WebFetch":
            let url = input["url"]?.stringValue ?? ""
            action = String(localized: "Fetched \(URL(string: url)?.host() ?? url)", bundle: #bundle, comment: "A chat's call: Claude read a web page")
            detail = url
        case "WebSearch":
            action = String(localized: "Searched the web for “\(input["query"]?.stringValue ?? "")”", bundle: #bundle, comment: "A chat's call")
        case "Agent", "Task":
            let title = description ?? input["subagent_type"]?.stringValue ?? String(localized: "Agent", bundle: #bundle)
            action = input["run_in_background"]?.boolValue == true
                ? String(localized: "Started an agent in the background: \(title)", bundle: #bundle, comment: "A chat's call: Claude started a sub-agent that keeps working")
                : String(localized: "Ran an agent: \(title)", bundle: #bundle, comment: "A chat's call: Claude ran a sub-agent")
            detail = input["prompt"]?.stringValue
        case "SendMessage":
            action = String(localized: "Sent a message to an agent", bundle: #bundle, comment: "A chat's call")
        case "Workflow":
            action = String(localized: "Started a workflow: \(description ?? input["name"]?.stringValue ?? String(localized: "Workflow", bundle: #bundle))",
                            bundle: #bundle, comment: "A chat's call: Claude started a workflow of agents")
        case "TodoWrite":
            action = String(localized: "Updated the to-do list", bundle: #bundle, comment: "A chat's call")
        case "ExitPlanMode":
            action = String(localized: "Presented a plan", bundle: #bundle, comment: "A chat's call")
        case "Skill":
            action = String(localized: "Used the skill \(input["skill"]?.stringValue ?? input["command"]?.stringValue ?? "")", bundle: #bundle, comment: "A chat's call")
        default:
            return nil
        }
        var call = ChatToolCall(action: action, reference: nil)
        call.detail = detail
        return call
    }

    /// The card's title for the CLI's request about one of these tools; nil for another.
    static func request(_ name: String, input: JSONValue) -> String? {
        switch name {
        case "Bash":
            String(localized: "Claude wants to run a command", bundle: #bundle)
        case "WebFetch":
            String(localized: "Claude wants to fetch \(input["url"]?.stringValue.flatMap { URL(string: $0)?.host() } ?? input["url"]?.stringValue ?? "")", bundle: #bundle)
        case "WebSearch":
            String(localized: "Claude wants to search the web", bundle: #bundle)
        case "Agent", "Task":
            String(localized: "Claude wants to start an agent", bundle: #bundle)
        case "Workflow":
            String(localized: "Claude wants to start a workflow", bundle: #bundle)
        case "ExitPlanMode":
            String(localized: "Claude wants to leave Plan Only", bundle: #bundle, comment: "The card of a plan Claude presents in Plan Only")
        default:
            nil
        }
    }
}
