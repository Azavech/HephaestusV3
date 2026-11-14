import Foundation
import Yams

/// A YAML value kept exactly as it was read: each scalar with its text, its resolved tag and its
/// quoting, each sequence and mapping with its order and its style. Writing it back gives the same
/// text, so a file keeps the keys V3 doesn't use, and their layout (docs/data.md › Unknown keys).
///
/// Decode it only through `YAMLCoding`, which gives the decoder the parsed document; any other
/// decoder gets a value rebuilt from its containers, without the source's quoting and tags.
public indirect enum RawYAML: Sendable, Hashable {
    case scalar(Scalar)
    case sequence([RawYAML], style: CollectionStyle)
    case mapping(YAMLMapping, style: CollectionStyle)

    /// A scalar: its text, its tag as the parser resolved it, and its quoting.
    public struct Scalar: Sendable, Hashable {
        public var text: String
        /// The resolved tag, such as `tag:yaml.org,2002:str` or `tag:yaml.org,2002:int`.
        public var tag: String
        public var style: ScalarStyle

        public init(_ text: String, tag: String = Tag.Name.str.rawValue, style: ScalarStyle = .any) {
            self.text = text
            self.tag = tag
            self.style = style
        }
    }

    /// How a scalar is written, as Yams names it.
    public enum ScalarStyle: UInt32, Sendable, Hashable {
        case any, plain, singleQuoted, doubleQuoted, literal, folded
    }

    /// How a sequence or a mapping is written: on lines (block), or inline (flow), as an empty `[]` or
    /// `{}`.
    public enum CollectionStyle: UInt32, Sendable, Hashable {
        case any, block, flow
    }

    /// The plain `null` scalar.
    public static let null = RawYAML.scalar(Scalar("null", tag: Tag.Name.null.rawValue, style: .plain))

    /// The value of a parsed node. An alias, which the parser leaves only when it can't resolve it,
    /// becomes `null`.
    public init(_ node: Node) {
        switch node {
        case .scalar(let scalar):
            self = .scalar(Scalar(scalar.string, tag: node.tag.rawValue,
                                  style: ScalarStyle(rawValue: scalar.style.rawValue) ?? .any))
        case .sequence(let sequence):
            self = .sequence(sequence.map(RawYAML.init), style: CollectionStyle(rawValue: sequence.style.rawValue) ?? .any)
        case .mapping(let mapping):
            let entries = mapping.map { YAMLMapping.Entry(key: $0.key.string ?? "", value: RawYAML($0.value)) }
            self = .mapping(YAMLMapping(entries), style: CollectionStyle(rawValue: mapping.style.rawValue) ?? .any)
        case .alias:
            self = .null
        }
    }

    /// The node Yams writes for this value.
    public var node: Node {
        switch self {
        case .scalar(let scalar):
            return .scalar(Node.Scalar(scalar.text, Tag(Tag.Name(rawValue: scalar.tag)),
                                       Node.Scalar.Style(rawValue: scalar.style.rawValue) ?? .any))
        case .sequence(let values, let style):
            return .sequence(Node.Sequence(values.map(\.node), Tag(.seq),
                                           Node.Sequence.Style(rawValue: style.rawValue) ?? .any))
        case .mapping(let mapping, let style):
            let pairs = mapping.entries.map { (Node(stringLiteral: $0.key), $0.value.node) }
            return .mapping(Node.Mapping(pairs, Tag(.map), Node.Mapping.Style(rawValue: style.rawValue) ?? .any))
        }
    }

    /// True for a `null` scalar: plain `~`, `null`, `Null`, `NULL` or an empty value.
    public var isNull: Bool {
        if case .scalar(let scalar) = self { return scalar.tag == Tag.Name.null.rawValue }
        return false
    }
}

/// The entries of a YAML mapping in the order they were read: the keys a file holds that its type
/// doesn't know (docs/data.md › Unknown keys).
public struct YAMLMapping: Sendable, Hashable, RandomAccessCollection, ExpressibleByDictionaryLiteral {
    public struct Entry: Sendable, Hashable {
        public var key: String
        public var value: RawYAML

        public init(key: String, value: RawYAML) {
            self.key = key
            self.value = value
        }
    }

    public private(set) var entries: [Entry]

    public init(_ entries: [Entry] = []) {
        self.entries = entries
    }

    public init(dictionaryLiteral elements: (String, RawYAML)...) {
        entries = elements.map { Entry(key: $0.0, value: $0.1) }
    }

    public var startIndex: Int { entries.startIndex }
    public var endIndex: Int { entries.endIndex }
    public subscript(position: Int) -> Entry { entries[position] }

    /// The value of a key, or nil when the mapping doesn't have it.
    public subscript(key: String) -> RawYAML? {
        get { entries.first { $0.key == key }?.value }
        set {
            if let index = entries.firstIndex(where: { $0.key == key }) {
                if let newValue { entries[index].value = newValue } else { entries.remove(at: index) }
            } else if let newValue {
                entries.append(Entry(key: key, value: newValue))
            }
        }
    }

    public var keys: [String] { entries.map(\.key) }
}

// MARK: - Coding

extension RawYAML: YAMLEncodable {
    /// Yams writes the node itself, with its tags and styles.
    public func box() -> Node { node }
}

extension RawYAML: Codable {
    public init(from decoder: any Decoder) throws {
        if let resolver = decoder.userInfo[YAMLCoding.nodeResolverKey] as? NodeResolver,
           let node = resolver.node(at: decoder.codingPath) {
            self.init(node)
            return
        }
        // Another decoder: rebuilt from the containers, every scalar as a string.
        if var array = try? decoder.unkeyedContainer() {
            var values: [RawYAML] = []
            while !array.isAtEnd { values.append(try array.decode(RawYAML.self)) }
            self = .sequence(values, style: .any)
        } else if let object = try? decoder.container(keyedBy: AnyKey.self) {
            let entries = try object.allKeys.map { YAMLMapping.Entry(key: $0.stringValue, value: try object.decode(RawYAML.self, forKey: $0)) }
            self = .mapping(YAMLMapping(entries), style: .any)
        } else {
            let single = try decoder.singleValueContainer()
            self = single.decodeNil() ? .null : .scalar(Scalar(try single.decode(String.self)))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        // Yams calls `box()`; this path serves other encoders.
        switch self {
        case .scalar(let scalar):
            var single = encoder.singleValueContainer()
            if isNull { try single.encodeNil() } else { try single.encode(scalar.text) }
        case .sequence(let values, _):
            var array = encoder.unkeyedContainer()
            for value in values { try array.encode(value) }
        case .mapping(let mapping, _):
            var object = encoder.container(keyedBy: AnyKey.self)
            for entry in mapping { try object.encode(entry.value, forKey: AnyKey(entry.key)) }
        }
    }
}

/// Finds the parsed node at a coding path of the document being decoded.
struct NodeResolver: @unchecked Sendable {
    // `Node` isn't `Sendable`; the resolver only reads it, on the decoding thread.
    let root: Node

    func node(at codingPath: [any CodingKey]) -> Node? {
        var node = root
        for key in codingPath {
            switch node {
            case .mapping(let mapping):
                guard let child = mapping[key.stringValue] else { return nil }
                node = child
            case .sequence(let sequence):
                guard let index = key.intValue, sequence.indices.contains(index) else { return nil }
                node = sequence[index]
            case .scalar, .alias:
                return nil
            }
        }
        return node
    }
}

/// A coding key for any string or index.
public struct AnyKey: CodingKey, Hashable, Sendable {
    public var stringValue: String
    public var intValue: Int?

    public init(_ string: String) {
        stringValue = string
        intValue = nil
    }

    public init?(stringValue: String) { self.init(stringValue) }

    public init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}
