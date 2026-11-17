import FileStorage
import Foundation
import MCPKit

/// What `get_attachment` returns of a ticket's file (docs/mcp.md › get_attachment): an image as a
/// `ClaudeImage`; a text as its text, up to `maxTextBytes`; anything else refused, with its path.
nonisolated enum AttachmentContent {
    /// The most of a text Claude gets; the rest is cut, and `truncated` says so.
    static let maxTextBytes = 256 * 1024

    /// The tool's result for the file at `url`, which the ticket lists as `name` of `contentType`.
    static func read(_ url: URL, name: String, contentType: String) throws(ToolError) -> JSONValue {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw ToolError(.notFound, "The file of attachment \(name) is missing: \(url.path).")
        }
        if ClaudeImage.isImage(contentType: contentType, url: url) {
            guard let image = ClaudeImage(data) else {
                throw ToolError(.invalid, "Attachment \(name) can't be read as an image.")
            }
            return ["type": "image", "data": .string(image.data.base64EncodedString()), "mimeType": .string(image.mimeType)]
        }
        guard let text = text(data) else {
            throw ToolError(.invalid, "Attachment \(name) is \(contentType), neither an image nor a text: its path is \(url.path).")
        }
        return ["name": .string(name), "contentType": .string(contentType), "text": .string(text.text), "truncated": .bool(text.truncated)]
    }

    /// The file as UTF-8 text without NUL characters, cut at `maxTextBytes` on a character's boundary; nil for
    /// anything else.
    static func text(_ data: Data) -> (text: String, truncated: Bool)? {
        let truncated = data.count > maxTextBytes
        var bytes = truncated ? data.prefix(maxTextBytes) : data
        guard !bytes.contains(0) else { return nil }
        // A cut may fall inside a character: up to three bytes are dropped until the rest decodes.
        for _ in 0..<(truncated ? 4 : 1) {
            if let text = String(data: bytes, encoding: .utf8) {
                return (text, truncated)
            }
            bytes = bytes.dropLast()
        }
        return nil
    }
}
