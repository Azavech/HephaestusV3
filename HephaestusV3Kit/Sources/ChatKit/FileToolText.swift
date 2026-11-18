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
