import Foundation
import ImageIO
import MCPKit
import UniformTypeIdentifiers

/// What `get_attachment` returns of a ticket's file (docs/mcp.md › get_attachment): an image as an image, made
/// at most `maxPixels` on its longest side; a text as its text, up to `maxTextBytes`; anything else refused, with
/// its path.
nonisolated enum AttachmentContent {
    /// The longest side of an image Claude gets: larger ones are scaled down to it.
    static let maxPixels = 1568
    /// The most of a text Claude gets; the rest is cut, and `truncated` says so.
    static let maxTextBytes = 256 * 1024
    /// The most an image's data may hold as PNG before it is sent as JPEG.
    static let maxImageBytes = 3_750_000

    /// The tool's result for the file at `url`, which the ticket lists as `name` of `contentType`.
    static func read(_ url: URL, name: String, contentType: String) throws(ToolError) -> JSONValue {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw ToolError(.notFound, "The file of attachment \(name) is missing: \(url.path).")
        }
        if isImage(contentType: contentType, url: url) {
            guard let image = image(data) else {
                throw ToolError(.invalid, "Attachment \(name) can't be read as an image.")
            }
            return ["type": "image", "data": .string(image.data.base64EncodedString()), "mimeType": .string(image.mimeType)]
        }
        guard let text = text(data) else {
            throw ToolError(.invalid, "Attachment \(name) is \(contentType), neither an image nor a text: its path is \(url.path).")
        }
        return ["name": .string(name), "contentType": .string(contentType), "text": .string(text.text), "truncated": .bool(text.truncated)]
    }

    /// An image by its content type or by its name's extension: a file stored as `application/octet-stream` may
    /// still be named `.png`.
    static func isImage(contentType: String, url: URL) -> Bool {
        UTType(mimeType: contentType)?.conforms(to: .image) == true || UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }

    /// The image as PNG, at most `maxPixels` on its longest side, its orientation applied; as JPEG when the PNG
    /// would be over `maxImageBytes`. Nil when ImageIO can't read it.
    static func image(_ data: Data) -> (data: Data, mimeType: String)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? maxPixels
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? maxPixels
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxPixels, max(width, height)),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        if let png = encode(image, as: .png), png.count <= maxImageBytes {
            return (png, "image/png")
        }
        return encode(image, as: .jpeg, quality: 0.8).map { ($0, "image/jpeg") }
    }

    private static func encode(_ image: CGImage, as type: UTType, quality: Double? = nil) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { return nil }
        let options = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, image, options)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
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
