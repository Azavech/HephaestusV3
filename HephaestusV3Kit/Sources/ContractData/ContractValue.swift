import Foundation
import Yams

/// A value of a contract, YAML or JSON, with its mappings in the file's order (docs/data.md › Contracts).
public enum ContractValue: Sendable, Hashable {
    case null
    case bool(Bool)
    /// A number, with its text as written, so that `1.50` is written back as it was.
    case number(Double, text: String)
    case string(String)
    case array([ContractValue])
    case object([Member])

    public struct Member: Sendable, Hashable {
        public let key: String
        public let value: ContractValue

        public init(_ key: String, _ value: ContractValue) {
            self.key = key
            self.value = value
        }
    }

    /// Parses YAML, or JSON, which YAML reads too. Throws the parser's message.
    public static func parse(_ text: String) throws -> ContractValue {
        guard let node = try Yams.compose(yaml: text) else { return .null }
        return ContractValue(node)
    }

    init(_ node: Node) {
        switch node {
        case .scalar(let scalar):
            switch node.tag.rawValue {
            case Tag.Name.null.rawValue: self = .null
            case Tag.Name.bool.rawValue: self = node.bool.map(ContractValue.bool) ?? .string(scalar.string)
            case Tag.Name.int.rawValue, Tag.Name.float.rawValue: self = node.float.map { .number($0, text: scalar.string) } ?? .string(scalar.string)
            default: self = .string(scalar.string)
            }
        case .sequence(let sequence):
            self = .array(sequence.map(ContractValue.init))
        case .mapping(let mapping):
            var members: [Member] = []
            var merged: [Member] = []
            for (key, value) in mapping {
                guard key.string == "<<" else {
                    members.append(Member(key.string ?? "", ContractValue(value)))
                    continue
                }
                // A YAML merge key (`<<: *errors`) adds the members of the merged mappings that aren't set, as V2 did.
                let sources: [Node] = switch value {
                case .mapping: [value]
                case .sequence(let sequence): Array(sequence)
                default: []
                }
                for source in sources {
                    if case .object(let sourceMembers) = ContractValue(source) {
                        merged.append(contentsOf: sourceMembers)
                    }
                }
            }
            for member in merged where !members.contains(where: { $0.key == member.key }) {
                members.append(member)
            }
            self = .object(members)
        case .alias:
            self = .null
        }
    }

    public subscript(key: String) -> ContractValue? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.key == key }?.value
    }

    public var string: String? { if case .string(let value) = self { value } else { nil } }
    public var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    public var double: Double? { if case .number(let value, _) = self { value } else { nil } }
    public var array: [ContractValue]? { if case .array(let value) = self { value } else { nil } }
    public var members: [Member]? { if case .object(let value) = self { value } else { nil } }

    /// JSON with two-space indentation (or compact), members in order.
    public func json(pretty: Bool = true) -> String {
        var out = ""
        write(into: &out, indent: pretty ? 0 : nil)
        return out
    }

    private func write(into out: inout String, indent: Int?) {
        func newline(_ level: Int) { if let _ = indent { out += "\n" + String(repeating: "  ", count: level) } }
        let level = indent ?? 0
        switch self {
        case .null: out += "null"
        case .bool(let value): out += value ? "true" : "false"
        case .number(let value, let text):
            let plain = Double(text) != nil && !text.contains("_") && !text.hasPrefix("0x") && !text.hasPrefix("0o") && !text.hasPrefix("+")
            out += plain ? text : (value.rounded() == value && abs(value) < 1e15 ? String(Int(value)) : String(value))
        case .string(let value): out += Self.quoted(value)
        case .array(let values):
            guard !values.isEmpty else { out += "[]"; return }
            out += "["
            for (index, value) in values.enumerated() {
                if index > 0 { out += "," }
                newline(level + 1)
                value.write(into: &out, indent: indent.map { _ in level + 1 })
            }
            newline(level)
            out += "]"
        case .object(let members):
            guard !members.isEmpty else { out += "{}"; return }
            out += "{"
            for (index, member) in members.enumerated() {
                if index > 0 { out += "," }
                newline(level + 1)
                out += Self.quoted(member.key) + (indent == nil ? ":" : ": ")
                member.value.write(into: &out, indent: indent.map { _ in level + 1 })
            }
            newline(level)
            out += "}"
        }
    }

    static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case let c where c.value < 0x20: out += String(format: "\\u%04x", c.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
