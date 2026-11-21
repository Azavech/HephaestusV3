import FileStorage
import Foundation
import ProjectData
import UniformTypeIdentifiers

/// Who makes a change: the user on this Mac, or Claude from a chat (docs/data.md › Ticket history).
public enum TicketActor: Sendable, Hashable {
    /// The user, on the named Mac.
    case user(device: String)
    /// Claude: `chat` is the chat's id, or `external` for a terminal session.
    case claude(chat: String)
    /// The app on its own: the title `set-ticket-title` gives a ticket created without one (V2's `automatic`).
    case automatic

    public var isClaude: Bool { if case .claude = self { true } else { false } }
    var author: Author { isClaude ? .claude : .user }
    var historyAuthor: HistoryEntry.HistoryAuthor {
        switch self {
        case .user: .user
        case .claude: .claude
        case .automatic: .automatic
        }
    }
    var device: String? { if case .user(let device) = self { device } else { nil } }
    var chat: String? { if case .claude(let chat) = self { chat } else { nil } }
}

/// Why a ticket change failed, with its messages (docs/data.md › Ticket errors).
public enum TicketError: Error, Sendable, Hashable, CustomStringConvertible {
    /// A value breaks a rule.
    case invalid(String)
    /// A project, ticket, bundle, comment, attachment or file named doesn't exist.
    case notFound(String)
    /// The actor may not make this change.
    case forbidden(String)
    /// The item's state refuses it: Implement on a done ticket, Implement All on a bundle in progress.
    case conflict(String)
    /// A file can't be read, written or moved to the Trash.
    case storage(StorageError)
    /// The project's file can't take the new number.
    case project(ProjectError)

    public var description: String {
        switch self {
        case let .invalid(message), let .notFound(message), let .forbidden(message), let .conflict(message): message
        case let .storage(error): error.description + "."
        case let .project(error): error.description
        }
    }
}

/// The ticket rules that need no file: titles, attachment names and limits.
public enum TicketRules {
    /// The largest attachment, and the largest set of attachments of one change: 20 MiB.
    public static let attachmentLimit = 20 * 1024 * 1024
    /// A stored attachment file name (`<id>-<name>`) is at most this many UTF-8 bytes.
    public static let storedNameLimit = 213

    /// A title, trimmed: 1 to 200 characters on one line.
    public static func title(_ value: String) throws(TicketError) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isNewline), (1...200).contains(trimmed.count) else {
            throw .invalid("Title must be 1 to 200 characters on one line.")
        }
        return trimmed
    }

    /// A title from Claude's answer to `set-ticket-title`: its first line that isn't empty, trimmed, without a
    /// heading's `#`s or one pair of quotes around it, cut to 200 characters; nil when nothing is left. The app
    /// takes the answer as it comes: what Claude writes is the skill's to say.
    public static func title(fromAnswer answer: String) -> String? {
        for line in lines(answer) {
            var text = line.trimmingCharacters(in: .whitespaces)
            while text.hasPrefix("#") {
                text.removeFirst()
            }
            text = text.trimmingCharacters(in: .whitespaces)
            for (open, close) in [("\"", "\""), ("“", "”"), ("'", "'"), ("‘", "’"), ("«", "»")] where text.count >= 2 && text.hasPrefix(open) && text.hasSuffix(close) {
                text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                break
            }
            let cut = String(text.prefix(200)).trimmingCharacters(in: .whitespaces)
            if !cut.isEmpty { return cut }
        }
        return nil
    }

    /// The title of a ticket created without one: the description's first line that is neither empty nor a
    /// heading, trimmed and cut to 60 characters; `Untitled Ticket` without one.
    public static func provisionalTitle(from description: String) -> String {
        for line in lines(description) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let cut = String(trimmed.prefix(60)).trimmingCharacters(in: .whitespaces)
            if !cut.isEmpty { return cut }
        }
        return "Untitled Ticket"
    }

    /// The title of a bundle created without one: its tickets' titles joined with `, `, cut to 60 characters.
    public static func provisionalBundleTitle(from titles: [String]) -> String {
        let cut = String(titles.joined(separator: ", ").prefix(60)).trimmingCharacters(in: .whitespaces)
        return cut.isEmpty ? "Untitled Bundle" : cut
    }

    /// CR LF and lone CR become LF.
    public static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// Labels trimmed, empty ones dropped, each once in the order given.
    public static func labels(_ labels: [String]) -> [String] {
        var seen: Set<String> = []
        return labels.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// The lines of a text split at LF, CR LF or CR.
    static func lines(_ text: String) -> [String] {
        normalized(text).components(separatedBy: "\n")
    }

    // MARK: Attachments

    /// A file name as stored: `/`, `:` and control characters become `_`, an empty name `file`, and the part
    /// before the extension is shortened by whole characters until `<id>-<name>` fits in 213 bytes.
    public static func attachmentName(_ name: String, id: UUID) -> String {
        var cleaned = String(name.unicodeScalars.map { scalar -> Character in
            scalar == "/" || scalar == ":" || scalar.value < 0x20 || scalar.value == 0x7F ? "_" : Character(scalar)
        })
        if cleaned.isEmpty { cleaned = "file" }
        let limit = storedNameLimit - id.uuidString.utf8.count - 1
        guard cleaned.utf8.count > limit else { return cleaned }
        let dot = cleaned.lastIndex(of: ".").flatMap { $0 == cleaned.startIndex ? nil : $0 }
        var stem = String(dot.map { cleaned[..<$0] } ?? cleaned[...])
        let ext = dot.map { String(cleaned[$0...]) } ?? ""
        while !stem.isEmpty, (stem + ext).utf8.count > limit { stem.removeLast() }
        var result = stem + ext
        while result.utf8.count > limit { result.removeFirst() }
        return result.isEmpty ? "file" : result
    }

    /// The MIME type of a file name's extension, else `application/octet-stream`.
    public static func contentType(of name: String) -> String {
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? "application/octet-stream" : (UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream")
    }

    /// Image content types, shown as thumbnails.
    public static let imageTypes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/heic", "image/heif", "image/tiff",
                                                 "image/bmp", "image/webp"]
}

/// The checks of Implement and Implement All (docs/data.md › Implement chats), as V2's: a ticket neither done nor a
/// draft (Claude can't move a draft); a bundle To Do that lists a ticket that is loaded and isn't done.
public enum ImplementRules {
    /// Why the ticket can't be implemented; nil when it can.
    public static func refusal(of ticket: TicketFile) -> String? {
        switch ticket.status {
        case .done: "\(ticket.id) is done; set another status to implement it."
        case .draft: "\(ticket.id) is a draft; create it to implement it."
        case .todo, .inProgress, .review: nil
        }
    }

    /// Why the bundle can't be implemented; nil when it can. `ticket` gives a listed ticket, nil when it isn't loaded.
    public static func refusal(of bundle: BundleFile, ticket: (String) -> TicketFile?) -> String? {
        switch bundle.status {
        case .inProgress: return "\(bundle.id) is in progress; set it to To Do to implement it."
        case .done: return "\(bundle.id) is done; set it to To Do to implement it."
        case .todo: break
        }
        let left = bundle.ticketIDs.contains { ticket($0).map { $0.status != .done } ?? false }
        return left ? nil : "\(bundle.id) has no ticket left to implement."
    }
}
