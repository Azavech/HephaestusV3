import Foundation

/// What a request carries besides the operation: the parameters' values, the body of a media type, the
/// credentials and the added headers.
public struct RequestValues: Sendable, Hashable {
    /// By `<in>:<name>`, as they are stored.
    public var parameters: [String: String]
    public var mediaType: String?
    public var body: String
    /// By scheme name: `value` (API key), `username` and `password` (basic), `token` (bearer).
    public var credentials: [String: [String: String]]
    public var headers: [(name: String, value: String)]

    public init(parameters: [String: String] = [:], mediaType: String? = nil, body: String = "", credentials: [String: [String: String]] = [:],
                headers: [(name: String, value: String)] = []) {
        self.parameters = parameters
        self.mediaType = mediaType
        self.body = body
        self.credentials = credentials
        self.headers = headers
    }

    public static func == (lhs: RequestValues, rhs: RequestValues) -> Bool {
        lhs.parameters == rhs.parameters && lhs.mediaType == rhs.mediaType && lhs.body == rhs.body && lhs.credentials == rhs.credentials
            && lhs.headers.map(\.name) == rhs.headers.map(\.name) && lhs.headers.map(\.value) == rhs.headers.map(\.value)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(parameters)
        hasher.combine(body)
    }

    public static func key(_ parameter: OpenAPIParameter) -> String { "\(parameter.location.rawValue):\(parameter.name)" }
}

/// Builds the HTTP request of an operation (docs/data.md › Contracts › Sending a request).
public enum RequestBuilder {
    /// Every byte but the RFC 3986 unreserved characters, percent-encoded.
    public static func encode(_ text: String) -> String {
        var allowed = CharacterSet()
        allowed.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    /// The URL: the base URL, the path with its parameters, then the query parameters and the API keys sent in
    /// the query.
    public static func url(_ operation: OpenAPIOperation, base: String, values: RequestValues, schemes: [SecurityScheme]) -> String {
        var path = operation.path
        for parameter in operation.parameters where parameter.location == .path {
            path = path.replacing("{\(parameter.name)}", with: encode(values.parameters[RequestValues.key(parameter)] ?? ""))
        }
        var query = operation.parameters.filter { $0.location == .query }.compactMap { parameter -> String? in
            guard let value = values.parameters[RequestValues.key(parameter)], !value.isEmpty else { return nil }
            return encode(parameter.name) + "=" + encode(value)
        }
        for scheme in schemes {
            if case .apiKey(let name, .query) = scheme.kind, let value = values.credentials[scheme.name]?["value"], !value.isEmpty {
                query.append(encode(name) + "=" + encode(value))
            }
        }
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        guard !query.isEmpty else { return trimmed + path }
        return trimmed + path + (trimmed.contains("?") ? "&" : "?") + query.joined(separator: "&")
    }

    /// The headers, in order: header parameters, `Cookie`, API keys in headers, `Authorization`, `Content-Type`
    /// when a body is sent, then the added headers, each replacing one of the same name.
    public static func headers(_ operation: OpenAPIOperation, values: RequestValues, schemes: [SecurityScheme], sendsBody: Bool) -> [(String, String)] {
        var headers: [(String, String)] = []
        for parameter in operation.parameters where parameter.location == .header {
            if let value = values.parameters[RequestValues.key(parameter)], !value.isEmpty { headers.append((parameter.name, value)) }
        }
        var cookies = operation.parameters.filter { $0.location == .cookie }.compactMap { parameter -> String? in
            guard let value = values.parameters[RequestValues.key(parameter)], !value.isEmpty else { return nil }
            return "\(parameter.name)=\(value)"
        }
        for scheme in schemes {
            if case .apiKey(let name, .cookie) = scheme.kind, let value = values.credentials[scheme.name]?["value"], !value.isEmpty {
                cookies.append("\(name)=\(value)")
            }
        }
        if !cookies.isEmpty { headers.append(("Cookie", cookies.joined(separator: "; "))) }
        // API keys in headers, then basic, then bearer.
        for scheme in schemes {
            if case .apiKey(let name, .header) = scheme.kind, let value = values.credentials[scheme.name]?["value"], !value.isEmpty {
                headers.append((name, value))
            }
        }
        for scheme in schemes where scheme.kind == .basic {
            let stored = values.credentials[scheme.name] ?? [:]
            let user = stored["username"] ?? "", password = stored["password"] ?? ""
            if !user.isEmpty || !password.isEmpty {
                headers.append(("Authorization", "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()))
            }
        }
        for scheme in schemes where scheme.kind == .bearer {
            if let token = values.credentials[scheme.name]?["token"], !token.isEmpty { headers.append(("Authorization", "Bearer \(token)")) }
        }
        if sendsBody, let type = values.mediaType { headers.append(("Content-Type", type)) }
        for added in values.headers where !added.name.trimmingCharacters(in: .whitespaces).isEmpty {
            headers.removeAll { $0.0.caseInsensitiveCompare(added.name) == .orderedSame }
            headers.append((added.name, added.value))
        }
        return headers
    }

    /// The request, or nil when its URL isn't one.
    public static func request(_ operation: OpenAPIOperation, base: String, values: RequestValues, schemes: [SecurityScheme]) -> URLRequest? {
        guard let url = URL(string: url(operation, base: base, values: values, schemes: schemes)) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = operation.method.uppercased()
        let sendsBody = operation.requestBody != nil && !values.body.isEmpty
        for (name, value) in headers(operation, values: values, schemes: schemes, sendsBody: sendsBody) {
            request.addValue(value, forHTTPHeaderField: name)
        }
        if sendsBody { request.httpBody = Data(values.body.utf8) }
        return request
    }
}

/// A response: its status, headers, body and how long it took.
public struct ContractResponse: Sendable, Hashable {
    public let status: Int
    /// Sorted by name.
    public let headers: [String]
    public let body: Data
    public let durationMs: Int

    public init(status: Int, headers: [String], body: Data, durationMs: Int) {
        self.status = status
        self.headers = headers
        self.body = body
        self.durationMs = durationMs
    }

    /// The body as text: pretty JSON when it is JSON, else UTF-8 as received; nil for a binary body.
    public var text: String? {
        guard let text = String(data: body, encoding: .utf8) else { return nil }
        if let value = try? ContractValue.parse(text), value.members != nil || value.array != nil,
           (try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed])) != nil {
            return value.json()
        }
        return text
    }
}

/// Sends requests with an ephemeral session, without cookies, cache or credential storage; an environment that
/// allows invalid certificates has a session of its own that accepts any server certificate.
public final class ContractHTTPClient: Sendable {
    private let strict: URLSession
    private let lenient: URLSession

    public init() {
        strict = URLSession(configuration: Self.configuration)
        lenient = URLSession(configuration: Self.configuration, delegate: TrustingDelegate(), delegateQueue: nil)
    }

    private static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        return configuration
    }

    /// Sends the request; throws the error's localized description when no response comes.
    public func send(_ request: URLRequest, allowInvalidCertificates: Bool) async throws(ContractCallError) -> ContractResponse {
        let start = ContinuousClock.now
        do {
            let (data, response) = try await (allowInvalidCertificates ? lenient : strict).data(for: request)
            let elapsed = ContinuousClock.now - start
            let http = response as? HTTPURLResponse
            let headers = (http?.allHeaderFields ?? [:]).map { "\($0.key): \($0.value)" }.sorted { $0.lowercased() < $1.lowercased() }
            return ContractResponse(status: http?.statusCode ?? 0, headers: headers, body: data,
                                    durationMs: Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000))
        } catch {
            throw ContractCallError(message: error.localizedDescription)
        }
    }
}

public struct ContractCallError: Error, Sendable, Hashable {
    public let message: String
}

/// Accepts any server certificate: only for environments whose `allowInvalidCertificates` is on.
private final class TrustingDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }
}
