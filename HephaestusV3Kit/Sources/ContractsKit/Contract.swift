import Foundation
import ToolsFoundation

/// An OpenAPI contract, reduced to what the window shows. In the real suite it is read from the
/// project's contract file; here it is sample data.
nonisolated struct Contract: Hashable, Sendable {
    let title: String
    let version: String
    let operations: [Operation]

    /// The tags, in the order their first operation appears.
    var tags: [String] {
        var seen: [String] = []
        for operation in operations where !seen.contains(operation.tag) {
            seen.append(operation.tag)
        }
        return seen
    }

    /// The operation whose `operationId` is `id`.
    func operation(_ id: Operation.ID) -> Operation? {
        operations.first { $0.id == id }
    }
}

nonisolated enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
    case head = "HEAD"
    case options = "OPTIONS"
    case trace = "TRACE"
}

/// One operation of the contract, with what the request builder needs to call it.
nonisolated struct Operation: Identifiable, Hashable, Sendable {
    /// The `operationId`.
    let id: String
    let method: HTTPMethod
    let path: String
    let summary: String
    let tag: String
    let parameters: [Parameter]
    /// An example body, for the operations that take one.
    let requestBody: String?
    let responses: [DocumentedResponse]
    /// What a sample's last call answered; nil for a contract of the app's data, whose calls the window keeps.
    let lastResponse: SampleResponse?
    /// The media type of `requestBody`.
    var mediaType: String? = nil
    /// The description, Markdown.
    var details = ""

    /// `GET /orders/{id}`: what the stored values and Claude's `api_call` name it by.
    var key: String { "\(method.rawValue) \(path)" }
}

nonisolated struct Parameter: Identifiable, Hashable, Sendable {
    enum Location: String, Sendable {
        case path
        case query
        case header
        case cookie
    }

    /// `path.id`, `query.limit`: a name is unique only within its location.
    var id: String { "\(location.rawValue).\(name)" }
    let name: String
    let location: Location
    let type: String
    let isRequired: Bool
    let example: String
}

nonisolated struct DocumentedResponse: Identifiable, Hashable, Sendable {
    var id: String { code }
    /// `200`, `4XX`, `default`.
    let code: String
    let description: String

    init(status: Int, description: String) {
        code = String(status)
        self.description = description
    }

    init(code: String, description: String) {
        self.code = code
        self.description = description
    }

    /// The code's number, for its color; 0 for `default`, `500` for `5XX`.
    var status: Int { Int(code) ?? Int(code.prefix(1)).map { $0 * 100 } ?? 0 }
}

/// A response the service gave.
nonisolated struct SampleResponse: Hashable, Sendable {
    let status: Int
    let duration: Duration
    let bytes: Int
    let body: String

    /// 400 and above.
    var isError: Bool { status >= 400 }

    /// How the duration reads: in milliseconds below a second ("84 ms"), in seconds with one decimal
    /// from a second ("4.2 sec"), in the locale's words.
    var durationStyle: Duration.UnitsFormatStyle {
        duration < .seconds(1)
            ? .units(allowed: [.milliseconds], width: .abbreviated)
            : .units(allowed: [.seconds], width: .abbreviated, fractionalPart: .show(length: 1))
    }
}

/// The request being written for one operation: a value for each parameter, and the body. It starts
/// from the contract's examples.
nonisolated struct RequestDraft: Hashable, Sendable {
    let operation: Operation
    private(set) var values: [Parameter.ID: String]
    var body: String

    init(operation: Operation) {
        self.operation = operation
        values = Dictionary(operation.parameters.map { ($0.id, $0.example) }) { first, _ in first }
        body = operation.requestBody ?? ""
    }

    /// The value typed for `parameter`.
    subscript(parameter: Parameter) -> String {
        get { values[parameter.id] ?? "" }
        set { values[parameter.id] = newValue }
    }

    /// The URL the request goes to on `environment`: the path with its parameters filled in, then the
    /// query parameters that have a value, as `?name=value&…`. Header parameters don't show.
    func url(on environment: DeploymentEnvironment) -> String {
        var path = operation.path
        for parameter in operation.parameters where parameter.location == .path {
            path = path.replacingOccurrences(of: "{\(parameter.name)}", with: self[parameter])
        }
        let query = operation.parameters
            .filter { $0.location == .query && !self[$0].isEmpty }
            .map { "\($0.name)=\(self[$0])" }
        let base = (environment.url ?? "").hasSuffix("/") ? String((environment.url ?? "").dropLast()) : (environment.url ?? "")
        return base + (query.isEmpty ? path : path + "?" + query.joined(separator: "&"))
    }
}
