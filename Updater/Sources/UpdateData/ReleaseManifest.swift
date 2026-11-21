import Foundation

/// `release.json`, the asset of every release that describes it (docs/release.md › release.json). Every member is
/// required; unknown members are ignored.
public struct ReleaseManifest: Codable, Sendable, Hashable {
    public var version: String
    public var build: Int
    /// The SHA-256 of the release's disk image, 64 lowercase hexadecimal digits.
    public var sha256: String
    /// The size of the disk image in bytes.
    public var size: Int
    /// The app's `LSMinimumSystemVersion`.
    public var minimumSystemVersion: String
    /// When `release.json` was written: `YYYY-MM-DDTHH:MM:SSZ`.
    public var published: Date
    public var notes: String

    public init(version: String, build: Int, sha256: String, size: Int, minimumSystemVersion: String, published: Date, notes: String) {
        self.version = version
        self.build = build
        self.sha256 = sha256
        self.size = size
        self.minimumSystemVersion = minimumSystemVersion
        self.published = published
        self.notes = notes
    }

    /// The disk image's asset: `HephaestusV3-<version>.dmg`.
    public var diskImageName: String { "HephaestusV3-\(version).dmg" }

    public var appVersion: AppVersion { AppVersion(version: version, build: build) }

    private enum CodingKeys: String, CodingKey {
        case version, build, sha256, size, minimumSystemVersion, published, notes
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(String.self, forKey: .version)
        build = try c.decode(Int.self, forKey: .build)
        sha256 = try c.decode(String.self, forKey: .sha256)
        size = try c.decode(Int.self, forKey: .size)
        minimumSystemVersion = try c.decode(String.self, forKey: .minimumSystemVersion)
        let text = try c.decode(String.self, forKey: .published)
        guard let date = Self.parsePublished(text) else {
            throw DecodingError.dataCorruptedError(forKey: .published, in: c, debugDescription: "published is not YYYY-MM-DDTHH:MM:SSZ")
        }
        published = date
        notes = try c.decode(String.self, forKey: .notes)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(build, forKey: .build)
        try c.encode(sha256, forKey: .sha256)
        try c.encode(size, forKey: .size)
        try c.encode(minimumSystemVersion, forKey: .minimumSystemVersion)
        try c.encode(Self.formatPublished(published), forKey: .published)
        try c.encode(notes, forKey: .notes)
    }

    /// The member that breaks its rule.
    public struct ValidationError: Error, Equatable, Sendable, CustomStringConvertible {
        public var field: String
        public var description: String { "release.json: \(field) breaks its rule" }
    }

    /// Checks the rules of docs/release.md › release.json.
    public func validate() throws(ValidationError) {
        guard Self.isVersion(version) else { throw ValidationError(field: "version") }
        guard build >= 1 else { throw ValidationError(field: "build") }
        guard sha256.utf8.count == 64, sha256.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }) else {
            throw ValidationError(field: "sha256")
        }
        guard size >= 1 else { throw ValidationError(field: "size") }
        guard Self.isSystemVersion(minimumSystemVersion) else { throw ValidationError(field: "minimumSystemVersion") }
    }

    /// `^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$`
    static func isVersion(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 3 && parts.allSatisfy { part in
            guard !part.isEmpty, part.utf8.allSatisfy({ (0x30...0x39).contains($0) }) else { return false }
            return part == "0" || part.first != "0"
        }
    }

    /// `^[0-9]+(\.[0-9]+){0,2}$`
    static func isSystemVersion(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return (1...3).contains(parts.count) && parts.allSatisfy { !$0.isEmpty && $0.utf8.allSatisfy { (0x30...0x39).contains($0) } }
    }

    static func parsePublished(_ text: String) -> Date? {
        let bytes = Array(text.utf8)
        guard bytes.count == 20, bytes[4] == 0x2D, bytes[7] == 0x2D, bytes[10] == 0x54, bytes[13] == 0x3A, bytes[16] == 0x3A,
              bytes[19] == 0x5A else { return nil }
        for index in [0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18] where !(0x30...0x39).contains(bytes[index]) {
            return nil
        }
        return publishedFormatter().date(from: text)
    }

    static func formatPublished(_ date: Date) -> String {
        publishedFormatter().string(from: date)
    }

    private static func publishedFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }
}
