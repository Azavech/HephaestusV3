import Foundation

/// An OpenAPI 3.0 or 3.1 contract, read with its `$ref` pointers resolved (docs/data.md › Contracts).
public struct OpenAPIContract: Sendable, Hashable {
    public let openapi: String
    public let title: String
    public let version: String
    /// The operations in the order of `paths`, and in a path `get`, `put`, `post`, `delete`, `options`, `head`,
    /// `patch`, `trace`.
    public let operations: [OpenAPIOperation]
    /// The schemes of `components.securitySchemes` V3 sends: API keys, HTTP basic and bearer.
    public let securitySchemes: [SecurityScheme]

    public static let methods = ["get", "put", "post", "delete", "options", "head", "patch", "trace"]

    /// The operation of a key `<METHOD> <path>`, or of an `operationId`.
    public func operation(_ name: String) -> OpenAPIOperation? {
        operations.first { $0.key == name } ?? operations.first { $0.operationID == name }
    }

    /// Reads a contract from its text; `file` is its place, for the `$ref` pointers to other files of `root`.
    public static func read(_ text: String, file: URL, root: URL) throws(ContractError) -> OpenAPIContract {
        let value: ContractValue
        do {
            value = try ContractValue.parse(text)
        } catch {
            throw .unreadable("\(error)")
        }
        guard value.members != nil else { throw .unreadable("The root is not a mapping.") }
        guard let openapi = value["openapi"].flatMap(Self.text), openapi.hasPrefix("3") else {
            throw .unreadable("The root has no openapi value starting with 3.")
        }
        let resolver = ContractResolver(root: root, file: file, document: value)
        var operations: [OpenAPIOperation] = []
        for path in value["paths"]?.members ?? [] {
            let (item, itemFile) = resolver.resolve(path.value, in: file)
            let shared = item["parameters"]?.array ?? []
            for method in methods {
                guard let operation = item[method], operation.members != nil else { continue }
                operations.append(OpenAPIOperation(method: method, path: path.key, value: operation, sharedParameters: shared,
                                                   rootSecurity: value["security"], resolver: resolver, file: itemFile))
            }
        }
        let schemes = (value["components"]?["securitySchemes"]?.members ?? []).compactMap { member -> SecurityScheme? in
            let (scheme, _) = resolver.resolve(member.value, in: file)
            return SecurityScheme(name: member.key, value: scheme)
        }
        return OpenAPIContract(openapi: openapi, title: value["info"]?["title"].flatMap(Self.text) ?? "",
                               version: value["info"]?["version"].flatMap(Self.text) ?? "", operations: operations, securitySchemes: schemes)
    }

    /// A string, or a number as written.
    static func text(_ value: ContractValue) -> String? {
        switch value {
        case .string(let text): text
        case .number(_, let text): text
        default: nil
        }
    }

    /// The schemes an operation's requirements name: its `security`, else the root's; with neither, every scheme.
    public func schemes(for operation: OpenAPIOperation) -> [SecurityScheme] {
        guard let names = operation.securityNames else { return securitySchemes }
        return securitySchemes.filter { names.contains($0.name) }
    }
}

public enum ContractError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The text isn't an OpenAPI 3.x contract.
    case unreadable(String)

    public var description: String {
        switch self {
        case .unreadable(let message): message
        }
    }
}

/// One operation: its place, its words, its parameters, body and documented responses.
public struct OpenAPIOperation: Sendable, Hashable, Identifiable {
    public let method: String
    public let path: String
    public let operationID: String?
    public let summary: String
    public let description: String
    public let tags: [String]
    public let parameters: [OpenAPIParameter]
    public let requestBody: RequestBody?
    public let responses: [DocumentedResponse]
    /// The security requirements' scheme names; nil when neither the operation nor the root has `security`.
    public let securityNames: Set<String>?

    /// `GET /orders/{id}`: what stored values and `api_call` name it by.
    public var key: String { "\(method.uppercased()) \(path)" }
    public var id: String { key }

    public struct RequestBody: Sendable, Hashable {
        public let isRequired: Bool
        /// Each media type and its prefilled body (docs/data.md › Contracts › Prefilled bodies).
        public let mediaTypes: [MediaType]
    }

    public struct MediaType: Sendable, Hashable {
        public let name: String
        public let example: String
    }

    public struct DocumentedResponse: Sendable, Hashable {
        public let code: String
        public let description: String
    }

    init(method: String, path: String, value: ContractValue, sharedParameters: [ContractValue], rootSecurity: ContractValue?,
         resolver: ContractResolver, file: URL) {
        self.method = method
        self.path = path
        operationID = value["operationId"]?.string
        summary = value["summary"]?.string ?? ""
        description = value["description"]?.string ?? ""
        tags = (value["tags"]?.array ?? []).compactMap(\.string)
        // An operation's parameter replaces the path item's with the same name and place.
        var merged: [OpenAPIParameter] = []
        for raw in sharedParameters + (value["parameters"]?.array ?? []) {
            guard let parameter = OpenAPIParameter(resolver.resolve(raw, in: file).0, resolver: resolver, file: file) else { continue }
            merged.removeAll { $0.name == parameter.name && $0.location == parameter.location }
            merged.append(parameter)
        }
        parameters = merged
        if let raw = value["requestBody"] {
            let (body, bodyFile) = resolver.resolve(raw, in: file)
            let types = (body["content"]?.members ?? []).map { member in
                MediaType(name: member.key, example: ContractSamples.body(for: member.value, mediaType: member.key, resolver: resolver, file: bodyFile))
            }
            requestBody = RequestBody(isRequired: body["required"]?.bool ?? false, mediaTypes: types)
        } else {
            requestBody = nil
        }
        responses = (value["responses"]?.members ?? []).map { member in
            DocumentedResponse(code: member.key, description: resolver.resolve(member.value, in: file).0["description"]?.string ?? "")
        }
        let security = value["security"] ?? rootSecurity
        securityNames = security.map { Set(($0.array ?? []).flatMap { $0.members?.map(\.key) ?? [] }) }
    }
}

/// A parameter of an operation.
public struct OpenAPIParameter: Sendable, Hashable {
    public enum Location: String, Sendable, Hashable, CaseIterable {
        case path, query, header, cookie
    }

    public let name: String
    public let location: Location
    public let isRequired: Bool
    /// The schema's type summary: `string`, `integer`, `Pet · object`.
    public let type: String
    /// The parameter's example, else its schema's, as text; empty without one.
    public let example: String
    public let description: String

    init?(_ value: ContractValue, resolver: ContractResolver, file: URL) {
        guard let name = value["name"]?.string, let location = value["in"]?.string.flatMap(Location.init(rawValue:)) else { return nil }
        self.name = name
        self.location = location
        isRequired = value["required"]?.bool ?? (location == .path)
        description = value["description"]?.string ?? ""
        let schema = value["schema"]
        type = schema.map { ContractSamples.typeSummary($0, resolver: resolver, file: file) } ?? "any"
        let example = value["example"] ?? value["examples"]?.members?.first.map { resolver.resolve($0.value, in: file).0["value"] ?? .null }
            ?? schema.flatMap { resolver.resolve($0, in: file).0["example"] }
        self.example = example.map(Self.text) ?? ""
    }

    static func text(_ value: ContractValue) -> String {
        switch value {
        case .string(let text): text
        case .number(_, let text): text
        case .bool(let flag): flag ? "true" : "false"
        case .null: ""
        default: value.json(pretty: false)
        }
    }
}

/// A security scheme V3 sends: an API key in a header, the query or a cookie; HTTP basic; HTTP bearer.
public struct SecurityScheme: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case apiKey(name: String, location: OpenAPIParameter.Location)
        case basic
        case bearer
    }

    public let name: String
    public let kind: Kind
    public let description: String

    init?(name: String, value: ContractValue) {
        self.name = name
        description = value["description"]?.string ?? ""
        switch (value["type"]?.string, value["scheme"]?.string?.lowercased()) {
        case ("apiKey", _):
            guard let key = value["name"]?.string, let place = value["in"]?.string.flatMap(OpenAPIParameter.Location.init(rawValue:)),
                  place != .path else { return nil }
            kind = .apiKey(name: key, location: place)
        case ("http", "basic"): kind = .basic
        case ("http", "bearer"): kind = .bearer
        default: return nil
        }
    }
}

/// Resolves `$ref` pointers in the document and in other files of the project's folder, at most 32 in a row.
final class ContractResolver: @unchecked Sendable {
    let root: URL
    private var files: [URL: ContractValue?]

    init(root: URL, file: URL, document: ContractValue) {
        self.root = root.standardizedFileURL
        files = [file.standardizedFileURL: document]
    }

    /// The value a `$ref` leads to, with the file it is in; the value itself when it has no `$ref`; `.null`
    /// for a ref that can't be resolved.
    func resolve(_ value: ContractValue, in file: URL) -> (ContractValue, URL) {
        var current = value
        var currentFile = file.standardizedFileURL
        for _ in 0..<32 {
            guard let ref = current["$ref"]?.string else { return (current, currentFile) }
            guard let target = target(of: ref, from: currentFile) else { return (.null, currentFile) }
            current = target.0
            currentFile = target.1
        }
        return (.null, currentFile)
    }

    /// The name a ref shows: its pointer's last token, else its file's name; nil without a ref.
    static func name(of value: ContractValue) -> String? {
        guard let ref = value["$ref"]?.string else { return nil }
        let parts = ref.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2, let last = parts[1].split(separator: "/").last { return String(last) }
        return (String(parts[0]) as NSString).lastPathComponent
    }

    private func target(of ref: String, from file: URL) -> (ContractValue, URL)? {
        let parts = ref.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let filePart = parts[0]
        var targetFile = file
        if !filePart.isEmpty {
            guard !filePart.contains(":"), !filePart.hasPrefix("/"), let decoded = filePart.removingPercentEncoding else { return nil }
            targetFile = file.deletingLastPathComponent().appendingPathComponent(decoded).standardizedFileURL
            guard targetFile.path.hasPrefix(root.path + "/") else { return nil }
        }
        guard let document = load(targetFile) else { return nil }
        guard parts.count == 2, !parts[1].isEmpty else { return (document, targetFile) }
        var value = document
        for token in parts[1].split(separator: "/", omittingEmptySubsequences: true) {
            let key = (String(token).removingPercentEncoding ?? String(token)).replacing("~1", with: "/").replacing("~0", with: "~")
            switch value {
            case .object: guard let next = value[key] else { return nil }; value = next
            case .array(let items): guard let index = Int(key), items.indices.contains(index) else { return nil }; value = items[index]
            default: return nil
            }
        }
        return (value, targetFile)
    }

    private func load(_ file: URL) -> ContractValue? {
        if let cached = files[file] { return cached }
        let value = (try? String(contentsOf: file, encoding: .utf8)).flatMap { try? ContractValue.parse($0) }
        files[file] = value
        return value
    }
}
