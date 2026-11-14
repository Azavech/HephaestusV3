import Foundation

/// A request's head: its request line and header fields.
struct HTTPHead: Sendable, Hashable {
    var method: String
    var path: String
    var version: String
    var headers: [(name: String, value: String)]
    /// The bytes the head takes, the leading empty lines and the final empty line included.
    var length: Int

    static func == (lhs: HTTPHead, rhs: HTTPHead) -> Bool {
        lhs.method == rhs.method && lhs.path == rhs.path && lhs.version == rhs.version && lhs.length == rhs.length
            && lhs.headers.map(\.name) == rhs.headers.map(\.name) && lhs.headers.map(\.value) == rhs.headers.map(\.value)
    }

    func hash(into hasher: inout Hasher) { hasher.combine(method); hasher.combine(path); hasher.combine(length) }

    /// The values of a field, its name compared without regard to case.
    func values(_ name: String) -> [String] {
        headers.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
    }

    var closesConnection: Bool {
        version == "HTTP/1.0" || values("Connection").contains { $0.lowercased().contains("close") }
    }
}

/// A response: status, headers, body.
struct HTTPResponse: Sendable, Hashable {
    var status: Int
    var headers: [String: String] = [:]
    var body = Data()
    /// The server closes the connection after it.
    var closes = false

    static let reasons = [100: "Continue", 200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                          404: "Not Found", 405: "Method Not Allowed", 413: "Content Too Large"]

    /// A rejection: plain text, `Connection: close`.
    static func rejection(_ status: Int, _ text: String, headers: [String: String] = [:]) -> HTTPResponse {
        var all = headers
        all["Content-Type"] = "text/plain; charset=utf-8"
        return HTTPResponse(status: status, headers: all, body: Data(text.utf8), closes: true)
    }

    static let malformed = rejection(400, "Bad Request: malformed HTTP request.")
    static let headTooLarge = rejection(413, "Content Too Large: the request head exceeds 65536 bytes.")
    static let bodyTooLarge = rejection(413, "Content Too Large: the request body exceeds 4194304 bytes.")
    static let unauthorized = rejection(401, "Unauthorized: missing or invalid bearer token.",
                                        headers: ["WWW-Authenticate": "Bearer realm=\"hephaestus\""])
    static let originRefused = rejection(403, "Forbidden: requests with an Origin header are refused.")
    static let notFound = rejection(404, "Not Found: the MCP endpoint is /mcp.")
    static let methodNotAllowed = rejection(405, "Method Not Allowed: use POST.", headers: ["Allow": "POST"])

    /// The bytes on the wire.
    var data: Data {
        var head = "HTTP/1.1 \(status) \(Self.reasons[status] ?? "Status")\r\n"
        var fields = headers
        fields["Content-Length"] = String(body.count)
        fields["Cache-Control"] = "no-store"
        if closes { fields["Connection"] = "close" }
        for name in fields.keys.sorted() { head += "\(name): \(fields[name]!)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + body
    }
}

/// Reading requests from the bytes of a connection (docs/mcp.md › Request handling).
enum HTTPParser {
    static let headLimit = 65_536
    static let bodyLimit = 4_194_304

    enum HeadResult: Hashable {
        case needMore
        case head(HTTPHead)
        case failure(HTTPResponse)
    }

    /// The head at the start of `buffer`; empty lines before it are skipped.
    static func head(in buffer: Data) -> HeadResult {
        let bytes = [UInt8](buffer)
        var start = 0
        while start + 1 < bytes.count, bytes[start] == 13, bytes[start + 1] == 10 { start += 2 }
        guard let end = find([13, 10, 13, 10], in: bytes, from: start) else {
            return bytes.count - start > headLimit ? .failure(.headTooLarge) : .needMore
        }
        guard end - start <= headLimit else { return .failure(.headTooLarge) }
        guard let text = String(bytes: bytes[start..<end], encoding: .utf8) else { return .failure(.malformed) }
        let lines = text.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, parts[1].hasPrefix("/") || parts[1].hasPrefix("http"),
              parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0" else { return .failure(.malformed) }
        var headers: [(name: String, value: String)] = []
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { return .failure(.malformed) }
            let name = String(line[..<colon])
            guard !name.contains(" ") else { return .failure(.malformed) }
            headers.append((name, line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
        }
        var target = String(parts[1])
        if let url = URLComponents(string: target), target.hasPrefix("http") { target = url.path.isEmpty ? "/" : url.path }
        let path = String(target.prefix { $0 != "?" })
        let head = HTTPHead(method: String(parts[0]), path: path, version: String(parts[2]), headers: headers, length: end + 4)
        let lengths = head.values("Content-Length")
        guard lengths.count <= 1, lengths.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCIIDigit) }) else { return .failure(.malformed) }
        let encodings = head.values("Transfer-Encoding")
        guard encodings.allSatisfy({ $0.lowercased() == "chunked" }) else { return .failure(.malformed) }
        return .head(head)
    }

    enum BodyResult: Hashable {
        case needMore
        case body(Data, consumed: Int)
        case failure(HTTPResponse)
    }

    /// The body after the head: the decoded chunks with `Transfer-Encoding: chunked`, else `Content-Length`
    /// bytes, else none. `consumed` counts the head too.
    static func body(of head: HTTPHead, in buffer: Data) -> BodyResult {
        let bytes = [UInt8](buffer)
        if !head.values("Transfer-Encoding").isEmpty {
            return chunked(bytes, from: head.length)
        }
        let length = Int(head.values("Content-Length").first ?? "0") ?? 0
        guard length <= bodyLimit else { return .failure(.bodyTooLarge) }
        guard bytes.count - head.length >= length else { return .needMore }
        return .body(Data(bytes[head.length..<(head.length + length)]), consumed: head.length + length)
    }

    private static func chunked(_ bytes: [UInt8], from start: Int) -> BodyResult {
        var index = start
        var body = Data()
        while true {
            guard let lineEnd = find([13, 10], in: bytes, from: index) else {
                return bytes.count - index > headLimit ? .failure(.malformed) : .needMore
            }
            guard lineEnd - index <= headLimit,
                  let line = String(bytes: bytes[index..<lineEnd], encoding: .ascii) else { return .failure(.malformed) }
            let sizeText = line.prefix { $0 != ";" }.trimmingCharacters(in: .whitespaces)
            guard let size = Int(sizeText, radix: 16), size >= 0 else { return .failure(.malformed) }
            index = lineEnd + 2
            if size == 0 {
                // Trailer fields, ignored, up to an empty line.
                while true {
                    guard let end = find([13, 10], in: bytes, from: index) else { return .needMore }
                    if end == index { return .body(body, consumed: end + 2) }
                    guard end - index <= headLimit else { return .failure(.malformed) }
                    index = end + 2
                }
            }
            guard body.count + size <= bodyLimit else { return .failure(.bodyTooLarge) }
            guard bytes.count >= index + size + 2 else { return .needMore }
            guard bytes[index + size] == 13, bytes[index + size + 1] == 10 else { return .failure(.malformed) }
            body.append(contentsOf: bytes[index..<(index + size)])
            index += size + 2
        }
    }

    private static func find(_ pattern: [UInt8], in bytes: [UInt8], from start: Int) -> Int? {
        guard bytes.count >= pattern.count, start <= bytes.count - pattern.count else { return nil }
        for index in start...(bytes.count - pattern.count) where bytes[index] == pattern[0] {
            if Array(bytes[index..<(index + pattern.count)]) == pattern { return index }
        }
        return nil
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
