import Foundation
import MCPKit
import UniformTypeIdentifiers

/// A file sent with a message, as V2's `Attachment` (docs/data.md › Chat items › Message files): stored once in
/// the chat's folder, `.hephaestus/chats/<CHAT-ID>/<id>-<name>`, and never changed.
public struct MessageAttachment: Sendable, Hashable, Identifiable {
    /// An uppercase UUID, unique in the chat.
    public var id: String
    /// The name shown: one path component, such as `screenshot.png`.
    public var name: String
    /// Relative to the project's `.hephaestus/`: `chats/<CHAT-ID>/<id>-<name>`.
    public var path: String
    /// A MIME type; `application/octet-stream` when the name's extension gives none.
    public var contentType: String
    /// In bytes; 0 when unknown.
    public var size: Int
    /// The keys V3 doesn't use, written back as read.
    public var otherKeys: [String: JSONValue] = [:]

    public init(id: String, name: String, path: String, contentType: String, size: Int) {
        self.id = id
        self.name = name
        self.path = path
        self.contentType = contentType
        self.size = size
    }

    /// The attachment of a file stored as `chats/<chatID>/<id>-<name>`, its type from its name's extension.
    public static func stored(id: String, name: String, chatID: String, size: Int) -> MessageAttachment {
        MessageAttachment(id: id, name: name, path: "chats/\(chatID)/\(id)-\(name)", contentType: contentType(ofName: name), size: size)
    }

    /// The MIME type of a file name's extension, `application/octet-stream` without one.
    public static func contentType(ofName name: String) -> String {
        let pathExtension = (name as NSString).pathExtension
        return UTType(filenameExtension: pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    /// The file, in the project whose folder is `root`: only for a `path` of the form `chats/<folder>/<name>`, each
    /// part one component other than `.` and `..`, whose real path, the links of its existing part resolved, lies
    /// in the project's `.hephaestus/` folder; nil otherwise. The file itself may be missing.
    public func url(inProject root: String) -> URL? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "chats", parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        let data = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(".hephaestus", isDirectory: true)
        let file = data.appendingPathComponent(path)
        guard ClaudeFileTools.resolved(file.path).hasPrefix(ClaudeFileTools.resolved(data.path) + "/") else { return nil }
        return file
    }

    var json: JSONValue {
        var object = otherKeys
        object["id"] = .string(id)
        object["name"] = .string(name)
        object["path"] = .string(path)
        object["contentType"] = .string(contentType)
        object["size"] = .int(size)
        return .object(object)
    }

    /// An attachment of a transcript's line; nil without `id`, `name` or `path`.
    init?(json: JSONValue) {
        guard var object = json.objectValue, let id = object["id"]?.stringValue, let name = object["name"]?.stringValue,
              let path = object["path"]?.stringValue else { return nil }
        self.init(id: id, name: name, path: path, contentType: object["contentType"]?.stringValue ?? "application/octet-stream",
                  size: object["size"]?.intValue ?? 0)
        for key in ["id", "name", "path", "contentType", "size"] {
            object[key] = nil
        }
        otherKeys = object
    }
}

extension FeedbackReport {
    /// The files of a feedback message of V3 1.0.31 to 1.0.33, which named them only in its text: each
    /// `- Screenshot: <path>` and `- Attachment: <path>` line after `Feedback context:` whose path is a file of
    /// the chat's own folder, `<root>/.hephaestus/chats/<chatID>/<id>-<name>`, in order. Their size is unknown.
    public static func files(inMessage text: String, chatID: String, root: String) -> [MessageAttachment] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(of: "Feedback context:") else { return [] }
        let folder = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(".hephaestus/chats/\(chatID)", isDirectory: true)
            .standardizedFileURL.path + "/"
        return lines[(start + 1)...].compactMap { line -> MessageAttachment? in
            let path: String
            if line.hasPrefix("- Screenshot: ") {
                path = String(line.dropFirst("- Screenshot: ".count))
            } else if line.hasPrefix("- Attachment: ") {
                path = String(line.dropFirst("- Attachment: ".count))
            } else {
                return nil
            }
            let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
            guard standardized.hasPrefix(folder) else { return nil }
            let stored = String(standardized.dropFirst(folder.count))
            // `<UUID>-<name>`: a UUID is 36 characters.
            guard !stored.contains("/"), stored.count > 37, UUID(uuidString: String(stored.prefix(36))) != nil,
                  stored[stored.index(stored.startIndex, offsetBy: 36)] == "-" else { return nil }
            let id = String(stored.prefix(36))
            return MessageAttachment.stored(id: id, name: String(stored.dropFirst(37)), chatID: chatID, size: 0)
        }
    }
}

extension MessageAttachment {
    /// The largest file a message carries, and the most its files may weigh together: 20 MB, as a ticket takes.
    public static let sizeLimit = 20 * 1024 * 1024

    /// Checks files before they are stored: none is a folder (`Folders cannot be attached.`), none is over 20 MB
    /// (`<name> is larger than 20 MB.`), and together they aren't (`The attachments of one request exceed 20 MB.`).
    public static func check(_ files: [URL]) throws(ChatError) {
        var total = 0
        for file in files {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            if values?.isDirectory == true { throw .invalid("Folders cannot be attached.") }
            let size = values?.fileSize ?? 0
            guard size <= sizeLimit else { throw .invalid("\(file.lastPathComponent) is larger than 20 MB.") }
            total += size
        }
        guard total <= sizeLimit else { throw .invalid("The attachments of one request exceed 20 MB.") }
    }

    /// Copies `files`, each under its name, into the chat's folder `folder` (`.hephaestus/chats/<chatID>/`) as
    /// `<UUID>-<name>`, and returns where each went with its attachment. A copy that fails removes those made and
    /// throws (`unavailable`, `<failure>: <reason>`).
    static func store(_ files: [(url: URL, name: String)], chatID: String, in folder: URL,
                      failure: String = "The files couldn't be stored") throws(ChatError) -> [(url: URL, attachment: MessageAttachment)] {
        var stored: [(url: URL, attachment: MessageAttachment)] = []
        do {
            if !files.isEmpty {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            for file in files {
                let fileID = UUID().uuidString
                let target = folder.appendingPathComponent("\(fileID)-\(file.name)")
                try FileManager.default.copyItem(at: file.url, to: target)
                let size = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                stored.append((target, .stored(id: fileID, name: file.name, chatID: chatID, size: size)))
            }
        } catch {
            for file in stored { try? FileManager.default.removeItem(at: file.url) }
            throw .unavailable("\(failure): \((error as NSError).localizedDescription)")
        }
        return stored
    }
}
