import FileStorage
import Foundation
import Yams

/// What a change of a memory sets; nil keeps the file's value.
public struct MemoryChange: Sendable, Hashable {
    public var name: String?
    public var description: String?
    /// One of `MemoryType.chosen`.
    public var type: MemoryType?
    public var body: String?

    public init(name: String? = nil, description: String? = nil, type: MemoryType? = nil, body: String? = nil) {
        self.name = name
        self.description = description
        self.type = type
        self.body = body
    }

    var setsFrontMatter: Bool { name != nil || description != nil || type != nil }
}

extension MemoryFolder {
    /// A name the app writes: 1 to 64 lowercase letters and digits in groups joined by single hyphens, not `memory`,
    /// whose file would be `MEMORY.md` on a case-insensitive volume.
    public static func isValidName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard (1...64).contains(bytes.count), name != "memory", bytes.first != UInt8(ascii: "-"), bytes.last != UInt8(ascii: "-"),
              !name.contains("--") else { return false }
        return bytes.allSatisfy { (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == UInt8(ascii: "-") }
    }

    /// Whether another memory has the name, or a file or folder `<name>.md` other than `file` exists, as the volume
    /// compares names.
    public func isTaken(_ name: String, except file: String? = nil) -> Bool {
        let listing = (try? list())?.memories ?? []
        if listing.contains(where: { $0.name == name && $0.file != file }) { return true }
        let candidate = (path as NSString).appendingPathComponent(name + ".md")
        guard FileManager.default.fileExists(atPath: candidate) else { return false }
        guard let file else { return true }
        return !Self.isSameFile(candidate, (path as NSString).appendingPathComponent(file))
    }

    static func isSameFile(_ first: String, _ second: String) -> Bool {
        let manager = FileManager.default
        guard let a = try? manager.attributesOfItem(atPath: first), let b = try? manager.attributesOfItem(atPath: second) else { return false }
        return (a[.systemFileNumber] as? Int) == (b[.systemFileNumber] as? Int) && (a[.systemNumber] as? Int) == (b[.systemNumber] as? Int)
    }

    // MARK: Changes

    /// Writes `<name>.md` with its name, description and type and an empty body, then appends its line to `MEMORY.md`,
    /// the folder made when missing. Returns the file's name.
    @discardableResult
    public func create(name: String, description: String, type: MemoryType) throws(MemoryFileError) -> String {
        guard Self.isValidName(name) else { throw MemoryFileError("Use 1–64 lowercase letters, digits and single hyphens.") }
        guard !isTaken(name) else { throw MemoryFileError("A memory named \(name) already exists.") }
        let index = try readIndex() ?? ""
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        } catch {
            throw MemoryFileError("The folder can't be made: \(error.localizedDescription)")
        }
        let file = name + ".md"
        var text = try MemoryText("")
        try text.apply(MemoryChange(name: name, description: description, type: type, body: ""), file: file)
        try write(text.written, to: file)
        var lines = index
        if !lines.isEmpty, !lines.hasSuffix("\n") { lines += "\n" }
        let hook = Self.lineBreaksToLF(description).replacing("\n", with: " ")
        lines += "- [\(name)](\(file)) — \(hook)\n"
        try write(lines, to: Self.indexName)
        return file
    }

    /// Changes a memory: its front matter in place, its body whole. A new name renames the file, then the link targets
    /// of `MEMORY.md`, then `[[old name]]` in the folder's other memories. Returns the file's name after the change.
    @discardableResult
    public func update(_ file: String, _ change: MemoryChange) throws(MemoryFileError) -> String {
        let current = try Self.readText((path as NSString).appendingPathComponent(file))
        var text = try MemoryText(current)
        let oldName = text.memory(file: file).summary.name
        var renamed: String?
        if let name = change.name, name != oldName {
            guard Self.isValidName(name) else { throw MemoryFileError("Use 1–64 lowercase letters, digits and single hyphens.") }
            guard !isTaken(name, except: file) else { throw MemoryFileError("A memory named \(name) already exists.") }
            renamed = name
        }
        let index = renamed == nil ? nil : try readIndex()
        try text.apply(change, file: file)
        try write(text.written, to: file)
        guard let newName = renamed else { return file }
        var newFile = newName + ".md"
        let oldPath = (path as NSString).appendingPathComponent(file)
        let newPath = (path as NSString).appendingPathComponent(newFile)
        if FileManager.default.fileExists(atPath: newPath), Self.isSameFile(newPath, oldPath) {
            newFile = file
        } else {
            do {
                try FileManager.default.moveItem(atPath: oldPath, toPath: newPath)
            } catch {
                throw MemoryFileError("The file can't be renamed: \(error.localizedDescription)")
            }
        }
        if let index, newFile != file {
            let changed = Self.retargeting(index, from: file, to: newFile)
            if changed != index { try write(changed, to: Self.indexName) }
        }
        try relink(oldName, to: newName, except: newFile)
        return newFile
    }

    /// Removes the lines of `MEMORY.md` that link to the memory, then moves its file to the Trash.
    public func delete(_ file: String) throws(MemoryFileError) {
        let index = try readIndex()
        if let index {
            let kept = Self.removingLines(of: file, from: index)
            if kept != index { try write(kept, to: Self.indexName) }
        }
        do {
            try trash.move(URL(fileURLWithPath: (path as NSString).appendingPathComponent(file)))
        } catch {
            throw MemoryFileError("The file can't be moved to the Trash: \(error.localizedDescription)")
        }
    }

    /// Replaces `MEMORY.md`, the folder made when missing.
    public func writeIndex(_ text: String) throws(MemoryFileError) {
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        } catch {
            throw MemoryFileError("The folder can't be made: \(error.localizedDescription)")
        }
        try write(text, to: Self.indexName)
    }

    // MARK: Helpers

    private func write(_ text: String, to file: String) throws(MemoryFileError) {
        do {
            _ = try AtomicFile.write(Data(text.utf8), to: url.appendingPathComponent(file))
        } catch {
            throw MemoryFileError("\(file) can't be written: \(error.localizedDescription)")
        }
    }

    /// `[[old]]` becomes `[[new]]` in the other memories, in file name order; nothing else of them changes.
    private func relink(_ oldName: String, to newName: String, except own: String) throws(MemoryFileError) {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).filter(Self.isMemoryFile).sorted()
        for name in names where name != own {
            guard let text = try? Self.readText((path as NSString).appendingPathComponent(name)), (try? MemoryText(text)) != nil,
                  text.contains("[[\(oldName)]]") else { continue }
            try write(text.replacing("[[\(oldName)]]", with: "[[\(newName)]]"), to: name)
        }
    }

    /// The pattern of a Markdown link whose target is `file` or `./file`.
    static func linkPattern(_ file: String) -> NSRegularExpression {
        // A literal pattern, escaped: it can't fail.
        try! NSRegularExpression(pattern: #"\]\((\./)?"# + NSRegularExpression.escapedPattern(for: file) + #"\)"#)
    }

    static func retargeting(_ index: String, from file: String, to newFile: String) -> String {
        let range = NSRange(index.startIndex..., in: index)
        let template = "]($1" + NSRegularExpression.escapedTemplate(for: newFile) + ")"
        return linkPattern(file).stringByReplacingMatches(in: index, range: range, withTemplate: template)
    }

    static func removingLines(of file: String, from index: String) -> String {
        let pattern = linkPattern(file)
        let lines = index.split(separator: "\n", omittingEmptySubsequences: false)
        let kept = lines.filter { line in
            let text = String(line)
            return pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil
        }
        return kept.joined(separator: "\n")
    }

    static func lineBreaksToLF(_ text: String) -> String {
        text.replacing("\r\n", with: "\n").replacing("\r", with: "\n")
    }
}

extension MemoryText {
    /// Applies a change (docs/data.md › Memories › Writing a memory file): values replaced in place, a missing `name`
    /// and `description` added first, a missing `type` last in `metadata`, a missing `metadata` last.
    mutating func apply(_ change: MemoryChange, file: String) throws(MemoryFileError) {
        if change.setsFrontMatter {
            var entries = mapping.entries
            func scalar(_ text: String) -> RawYAML {
                .scalar(RawYAML.Scalar(text, tag: Tag.Name.str.rawValue, style: text.contains("\n") ? .literal : .any))
            }
            var leading: [YAMLMapping.Entry] = []
            if let name = change.name {
                if let index = entries.firstIndex(where: { $0.key == "name" }) { entries[index].value = scalar(name) }
                else { leading.append(.init(key: "name", value: scalar(name))) }
            }
            if let description = change.description.map(MemoryFolder.lineBreaksToLF) {
                if let index = entries.firstIndex(where: { $0.key == "description" }) { entries[index].value = scalar(description) }
                else { leading.append(.init(key: "description", value: scalar(description))) }
            }
            entries = leading + entries
            if let type = change.type, type != .other {
                if let index = entries.firstIndex(where: { $0.key == "metadata" }) {
                    guard case .mapping(var metadata, let style) = entries[index].value else {
                        if entries[index].value.isNull {
                            entries[index].value = .mapping(YAMLMapping([.init(key: "type", value: scalar(type.rawValue))]), style: .block)
                            mapping = YAMLMapping(entries)
                            frontMatterChanged = true
                            return try applyBody(change)
                        }
                        throw MemoryFileError("type: the metadata of \(file) is not a mapping.")
                    }
                    metadata["type"] = scalar(type.rawValue)
                    entries[index].value = .mapping(metadata, style: style == .flow ? .block : style)
                } else {
                    entries.append(.init(key: "metadata", value: .mapping(YAMLMapping([.init(key: "type", value: scalar(type.rawValue))]),
                                                                         style: .block)))
                }
            }
            mapping = YAMLMapping(entries)
            if frontMatter == nil { frontMatter = "" }
            frontMatterChanged = true
        }
        try applyBody(change)
    }

    private mutating func applyBody(_ change: MemoryChange) throws(MemoryFileError) {
        if let body = change.body {
            self.body = MemoryFolder.lineBreaksToLF(body)
        }
        // A file without front matter whose body starts with a `---` line gets an empty one, so the body stays the body.
        if frontMatter == nil, body.hasPrefix("---\n") || body == "---" || body.hasPrefix("---\r") {
            frontMatter = ""
        }
    }

    /// The file's text: the front matter, when it has one, then the body.
    var written: String {
        guard let frontMatter else { return body }
        // A change of the body alone keeps the front matter as written, comments included.
        let yaml = frontMatterChanged ? (mapping.isEmpty ? "" : ((try? YAMLCoding.encode(RawYAML.mapping(mapping, style: .block))) ?? "")) : frontMatter
        let separator = yaml.isEmpty || yaml.hasSuffix("\n") ? "" : "\n"
        return "---\n" + yaml + separator + "---\n" + body
    }
}
