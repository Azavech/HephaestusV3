import FileStorage
import Foundation
import Yams

/// A memory's type, as the CLI writes it in `metadata.type`; `other` for a missing or unknown one.
public enum MemoryType: String, Sendable, Hashable, CaseIterable, Identifiable {
    case user, feedback, project, reference, other

    public var id: Self { self }

    /// The four a memory is given.
    public static let chosen: [MemoryType] = [.user, .feedback, .project, .reference]
}

/// A memory of a folder, as the list shows it.
public struct MemorySummary: Sendable, Hashable, Identifiable {
    /// The file's name, such as `user-role.md`: the memory's identity in its folder.
    public var file: String
    public var name: String
    public var description: String
    public var type: MemoryType

    public var id: String { file }

    public init(file: String, name: String, description: String, type: MemoryType) {
        self.file = file
        self.name = name
        self.description = description
        self.type = type
    }
}

/// A memory read whole.
public struct Memory: Sendable, Hashable {
    public var summary: MemorySummary
    /// Everything after the front matter's closing line, or the whole file without front matter.
    public var body: String
    /// The front matter's other keys as YAML, sorted by key; empty without any.
    public var otherFrontMatter: String

    public init(summary: MemorySummary, body: String, otherFrontMatter: String = "") {
        self.summary = summary
        self.body = body
        self.otherFrontMatter = otherFrontMatter
    }
}

/// What a memory folder holds: its memories sorted by name, then file name, and whether it has a `MEMORY.md`.
public struct MemoryListing: Sendable, Hashable {
    public var folder: String
    public var hasIndex: Bool
    public var memories: [MemorySummary]
    /// The files skipped, with why.
    public var skipped: [String: String]

    public init(folder: String, hasIndex: Bool = false, memories: [MemorySummary] = [], skipped: [String: String] = [:]) {
        self.folder = folder
        self.hasIndex = hasIndex
        self.memories = memories
        self.skipped = skipped
    }
}

/// Reads and writes a memory folder (docs/data.md › Memories), as V2 did: one Markdown file per memory, a YAML front
/// matter with `name`, `description` and `metadata.type`, and `MEMORY.md`, its index, one line per memory.
public struct MemoryFolder: Sendable {
    public let path: String
    let trash: Trash

    public init(path: String, trash: Trash = .system) {
        self.path = path
        self.trash = trash
    }

    public static let indexName = "MEMORY.md"
    /// Larger files are skipped.
    public static let maximumSize = 20 * 1024 * 1024

    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    public var indexPath: String { (path as NSString).appendingPathComponent(Self.indexName) }

    /// Whether a file name is a memory's: `.md`, not `MEMORY.md`, not hidden (letter case ignored).
    public static func isMemoryFile(_ name: String) -> Bool {
        name.lowercased().hasSuffix(".md") && name.lowercased() != indexName.lowercased() && !name.hasPrefix(".")
    }

    // MARK: Reading

    /// The folder's memories; a missing folder has none. Throws when the folder can't be read.
    public func list() throws(StorageError) -> MemoryListing {
        let manager = FileManager.default
        var isFolder: ObjCBool = false
        guard manager.fileExists(atPath: path, isDirectory: &isFolder) else { return MemoryListing(folder: path) }
        guard isFolder.boolValue else { throw .readFailed(path: path, reason: "it is not a folder") }
        let names: [String]
        do {
            names = try manager.contentsOfDirectory(atPath: path)
        } catch {
            throw .readFailed(path: path, reason: error.localizedDescription)
        }
        var listing = MemoryListing(folder: path)
        listing.hasIndex = names.contains { $0.lowercased() == Self.indexName.lowercased() }
            && manager.fileExists(atPath: indexPath, isDirectory: &isFolder) && !isFolder.boolValue
        for name in names where Self.isMemoryFile(name) {
            let filePath = (path as NSString).appendingPathComponent(name)
            guard manager.fileExists(atPath: filePath, isDirectory: &isFolder), !isFolder.boolValue else { continue }
            do throws(MemoryFileError) {
                listing.memories.append(try read(name).summary)
            } catch {
                listing.skipped[name] = error.reason
            }
        }
        listing.memories.sort { ($0.name, $0.file) < ($1.name, $1.file) }
        return listing
    }

    /// One memory, by its file name.
    public func read(_ file: String) throws(MemoryFileError) -> Memory {
        let filePath = (path as NSString).appendingPathComponent(file)
        let text = try Self.readText(filePath)
        let parts = try MemoryText(text)
        return parts.memory(file: file)
    }

    /// The text of `MEMORY.md`; nil when it doesn't exist.
    public func readIndex() throws(MemoryFileError) -> String? {
        guard FileManager.default.fileExists(atPath: indexPath) else { return nil }
        return try Self.readText(indexPath)
    }

    static func readText(_ path: String) throws(MemoryFileError) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        if let size = attributes?[.size] as? Int, size > maximumSize { throw MemoryFileError("larger than 20 MiB") }
        guard let data = FileManager.default.contents(atPath: path) else { throw MemoryFileError("it can't be read") }
        guard let text = String(data: data, encoding: .utf8) else { throw MemoryFileError("not valid UTF-8") }
        return text
    }
}

/// Why a memory file can't be read or written, in the user's words.
public struct MemoryFileError: Error, Sendable, Hashable, CustomStringConvertible {
    public var reason: String
    public init(_ reason: String) { self.reason = reason }
    public var description: String { reason }
}

/// A memory file split into its front matter and its body (docs/data.md › Memories): when the first line is exactly
/// `---`, the lines up to the next line exactly `---` are the front matter, a YAML mapping.
struct MemoryText {
    /// The front matter's text without its two lines; nil without front matter.
    var frontMatter: String?
    var mapping: YAMLMapping
    var body: String
    /// Whether a change set a front matter key: the mapping is then written again.
    var frontMatterChanged = false

    init(_ text: String) throws(MemoryFileError) {
        var text = text
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        func isFence(_ line: Substring) -> Bool { line == "---" || line == "---\r" }
        guard let first = lines.first, isFence(first) else {
            frontMatter = nil
            mapping = YAMLMapping()
            body = text
            return
        }
        guard let close = lines.dropFirst().firstIndex(where: isFence) else {
            throw MemoryFileError("its front matter has no closing line")
        }
        let yaml = lines[1..<close].joined(separator: "\n")
        frontMatter = yaml
        body = close + 1 < lines.count ? lines[(close + 1)...].joined(separator: "\n") : ""
        if yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            mapping = YAMLMapping()
            return
        }
        do {
            let node = try YAMLCoding.parseMapping(yaml)
            guard case .mapping(let parsed, _) = RawYAML(node) else { throw MemoryFileError("its front matter is not a mapping") }
            mapping = parsed
        } catch let error as MemoryFileError {
            throw error
        } catch {
            throw MemoryFileError("its front matter is not a YAML mapping")
        }
    }

    static func string(_ value: RawYAML?) -> String? {
        guard case .scalar(let scalar)? = value, scalar.tag == Tag.Name.str.rawValue else { return nil }
        return scalar.text
    }

    var metadata: YAMLMapping? {
        if case .mapping(let metadata, _)? = mapping["metadata"] { return metadata }
        return nil
    }

    var type: MemoryType {
        let written = Self.string(metadata?["type"]) ?? (metadata?["type"] == nil ? Self.string(mapping["type"]) : nil)
        guard let written, let type = MemoryType(rawValue: written), type != .other else { return .other }
        return type
    }

    func memory(file: String) -> Memory {
        let fileName = String(file.dropLast(3))
        let name = Self.string(mapping["name"]).flatMap { $0.isEmpty ? nil : $0 } ?? fileName
        let summary = MemorySummary(file: file, name: name, description: Self.string(mapping["description"]) ?? "", type: type)
        return Memory(summary: summary, body: body, otherFrontMatter: otherFrontMatter)
    }

    /// The keys but `name`, `description` and `metadata.type`, sorted by key, as YAML.
    var otherFrontMatter: String {
        var entries = mapping.entries.filter { $0.key != "name" && $0.key != "description" }
        if let index = entries.firstIndex(where: { $0.key == "metadata" }), case .mapping(let metadata, let style) = entries[index].value {
            let rest = metadata.entries.filter { $0.key != "type" }
            if rest.isEmpty { entries.remove(at: index) } else { entries[index].value = .mapping(YAMLMapping(rest), style: style) }
        }
        guard !entries.isEmpty else { return "" }
        entries.sort { $0.key < $1.key }
        return ((try? YAMLCoding.encode(RawYAML.mapping(YAMLMapping(entries), style: .block))) ?? "").trimmingCharacters(in: .newlines)
    }
}
