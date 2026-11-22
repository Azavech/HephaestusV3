import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An image as Claude gets it (docs/data.md › Claude images): at most `maxPixels` on its longest side, its
/// orientation applied, as PNG, or as JPEG when the PNG would be over `maxBytes`. `get_attachment` returns one; a
/// chat's message carries the feedback's.
public struct ClaudeImage: Sendable, Hashable {
    public let data: Data
    /// `image/png` or `image/jpeg`.
    public let mimeType: String

    /// The longest side Claude gets: larger images are scaled down to it.
    public static let maxPixels = 1568
    /// The most an image may hold as PNG before it is sent as JPEG.
    public static let maxBytes = 3_750_000

    /// The image in `data`, scaled; nil when ImageIO can't read it.
    public init?(_ data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? Self.maxPixels
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? Self.maxPixels
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(Self.maxPixels, max(width, height)),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        if let png = Self.encode(image, as: .png), png.count <= Self.maxBytes {
            self.data = png
            mimeType = "image/png"
        } else if let jpeg = Self.encode(image, as: .jpeg, quality: 0.8) {
            self.data = jpeg
            mimeType = "image/jpeg"
        } else {
            return nil
        }
    }

    /// The image file at `url`, scaled; nil when it can't be read as an image.
    /// The images of `urls`, read and converted off the caller's actor, in order; those that aren't images are left
    /// out. A large picture takes time to decode and scale.
    public static func load(_ urls: [URL]) async -> [ClaudeImage] {
        await Task.detached(priority: .userInitiated) { urls.compactMap { ClaudeImage(contentsOf: $0) } }.value
    }

    public init?(contentsOf url: URL) {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        self.init(data)
    }

    /// An image by its content type or by its name's extension: a file stored as `application/octet-stream` may
    /// still be named `.png`.
    public static func isImage(contentType: String?, url: URL) -> Bool {
        contentType.flatMap { UTType(mimeType: $0) }?.conforms(to: .image) == true
            || UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }

    private static func encode(_ image: CGImage, as type: UTType, quality: Double? = nil) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { return nil }
        let options = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, image, options)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
