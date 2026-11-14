import Foundation
import Yams

/// Reading and writing YAML files with Yams, in the files' layout (docs/data.md › Conventions).
///
/// Reading: UTF-8 (a leading byte order mark is skipped, CR LF accepted), exactly one document whose
/// root is a mapping, no mapping with the same key twice, any YAML style.
///
/// Writing: block style with two-space indentation, literal block style for strings with a line break,
/// quotes around strings YAML would read as another type, unlimited line width, LF line breaks. A
/// sequence that is the value of a key is not indented: its `- ` items start at the key's column, the
/// only layout libyaml writes. A `RawYAML` value is written as it was read.
public enum YAMLCoding {
    /// The `userInfo` key under which a decoder finds the parsed document, for `RawYAML`.
    public static let nodeResolverKey = CodingUserInfoKey(rawValue: "FileStorage.YAMLCoding.nodeResolver")!

    /// Encodes a value with the writing rules.
    public static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = YAMLEncoder()
        encoder.options = YAMLEncoder.Options(
            indent: 2,
            width: -1,
            allowUnicode: true,
            lineBreak: .ln,
            sequenceStyle: .block,
            mappingStyle: .block,
            newLineScalarStyle: .literal
        )
        return try encoder.encode(value)
    }

    /// Encodes a value as UTF-8 bytes.
    public static func encodeData<T: Encodable>(_ value: T) throws -> Data {
        Data(try encode(value).utf8)
    }

    /// Decodes a file's bytes. Throws `FileFormatError`, whose reason never quotes the content.
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decode(type, from: parseMapping(data))
    }

    /// Decodes a YAML text.
    public static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        try decode(type, from: parseMapping(text))
    }

    /// Decodes a parsed document.
    public static func decode<T: Decodable>(_ type: T.Type, from node: Node) throws -> T {
        do {
            return try YAMLDecoder().decode(type, from: node, userInfo: [nodeResolverKey: NodeResolver(root: node)])
        } catch {
            throw FileFormatError(FileFormatError.describe(error))
        }
    }

    /// Parses bytes that must be valid UTF-8 holding one YAML document whose root is a mapping.
    public static func parseMapping(_ data: Data) throws -> Node {
        guard let text = String(data: data, encoding: .utf8) else {
            throw FileFormatError("not valid UTF-8")
        }
        return try parseMapping(text)
    }

    /// Parses a text holding one YAML document whose root is a mapping, with no mapping holding the
    /// same key twice.
    public static func parseMapping(_ text: String) throws -> Node {
        var text = text
        if text.hasPrefix("\u{FEFF}") {
            text.removeFirst()
        }
        let node: Node?
        do {
            node = try Yams.compose(yaml: text)
        } catch YamlError.duplicatedKeysInMapping(let duplicates, _) {
            throw FileFormatError("the key \"\(duplicates.sorted().first ?? "")\" appears twice in one mapping")
        } catch {
            throw FileFormatError(FileFormatError.describe(error))
        }
        guard let node, case .mapping = node else {
            throw FileFormatError("the root of the document is not a mapping")
        }
        return node
    }
}
