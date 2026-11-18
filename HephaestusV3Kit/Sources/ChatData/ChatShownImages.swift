import FileStorage
import Foundation
import MCPKit

/// The images Claude shows with `show_image`, copied into the chat (docs/data.md › Images item), as V2's item.
public struct ImagesItem: Sendable, Hashable {
    public var id: String
    public var created: Date
    /// Markdown shown above the images, trimmed and not empty; nil when Claude gave none.
    public var caption: String?
    /// 1 to 10 PNG, JPEG, GIF or WebP images stored in the chat's folder, in the order Claude gave them.
    public var images: [MessageAttachment]

    public init(id: String = UUID().uuidString, created: Date, caption: String?, images: [MessageAttachment]) {
        self.id = id
        self.created = created
        self.caption = caption
        self.images = images
    }

    /// The image format of a file's first bytes, V2's rule: its content type, or nil for another file.
    public static func contentType(ofSignature data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if bytes.starts(with: Array("GIF87a".utf8)) || bytes.starts(with: Array("GIF89a".utf8)) { return "image/gif" }
        if bytes.count >= 12, bytes.starts(with: Array("RIFF".utf8)), Array(bytes[8..<12]) == Array("WEBP".utf8) { return "image/webp" }
        return nil
    }
}

extension ChatSession {
    /// `show_image`: checks V2's image rules in order, copies the images into the chat's folder, then adds an
    /// `images` item at the place of the call. Nothing is stored when a rule fails. A path is absolute, starts
    /// with `~/`, or is relative to the project's folder.
    @discardableResult
    public func postImages(_ chatID: String, paths: [String], caption: String?) throws(ChatError) -> ImagesItem {
        guard chats[chatID] != nil, let folder = folder(of: chatID) else { throw .notFound("Chat \(chatID) not found.") }
        guard (1...10).contains(paths.count) else { throw .invalid("show_image needs 1 to 10 images.") }
        var files: [(url: URL, name: String, type: String)] = []
        var total = 0
        for path in paths {
            let expanded = (path as NSString).expandingTildeInPath
            let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : folder.root.appendingPathComponent(expanded)
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true, FileManager.default.isReadableFile(atPath: url.path) else {
                throw .invalid("\(path) is not a readable file.")
            }
            let size = values?.fileSize ?? 0
            guard size <= MessageAttachment.sizeLimit else { throw .invalid("\(url.lastPathComponent) is larger than 20 MB.") }
            total += size
            guard total <= MessageAttachment.sizeLimit else { throw .invalid("The attachments of one request exceed 20 MB.") }
            let head = (try? FileHandle(forReadingFrom: url)).flatMap { handle in
                defer { try? handle.close() }
                return try? handle.read(upToCount: 12)
            } ?? Data()
            guard let type = ImagesItem.contentType(ofSignature: head) else {
                throw .invalid("\(path) is not a PNG, JPEG, GIF or WebP image.")
            }
            files.append((url, url.lastPathComponent, type))
        }
        let stored = try MessageAttachment.store(files.map { ($0.url, $0.name) }, chatID: chatID,
                                                 in: folder.chatsFolder.appendingPathComponent(chatID, isDirectory: true),
                                                 failure: "The images couldn't be stored")
        let images = zip(stored, files).map { stored, file in
            var attachment = stored.attachment
            attachment.contentType = file.type
            return attachment
        }
        let trimmed = caption?.trimmingCharacters(in: .whitespacesAndNewlines)
        let item = ImagesItem(created: now(), caption: trimmed?.isEmpty == false ? trimmed : nil, images: images)
        record(.images(item), in: chatID)
        return item
    }
}
