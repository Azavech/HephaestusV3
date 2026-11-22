import Foundation
import Synchronization
import Testing
@testable import MCPKit

/// A registry with one tool that echoes its arguments, and one that always fails.
private let registry = ToolRegistry([
    ToolOperation(name: "echo", description: "Echo.", inputSchema: .object(properties: [
        ("text", .string("Text.")),
        ("count", .integer("Count.", minimum: 1, maximum: 3)),
        ("mode", .string("Mode.", oneOf: ["a", "b"])),
        ("items", .array("Items.", of: .object(properties: [("label", .string())], required: ["label"]))),
    ], required: ["text"]), permission: .read) { arguments throws(ToolError) in arguments },
    ToolOperation(name: "fail", description: "Fail.", inputSchema: .object(), permission: .changeTickets) { _ throws(ToolError) in
        throw ToolError(.conflict, "It conflicts.")
    },
])

@Suite("JSON values and schemas")
struct SchemaTests {
    @Test("Integers, decimals and booleans stay apart; output has sorted keys")
    func values() throws {
        let value = try JSONValue.parse(Data(#"{"b":1,"a":1.5,"c":true,"d":null,"e":"x/y"}"#.utf8))
        #expect(value == ["b": 1, "a": .double(1.5), "c": true, "d": nil, "e": "x/y"])
        #expect(value.text == #"{"a":1.5,"b":1,"c":true,"d":null,"e":"x/y"}"#)
        #expect(value.removingNullMembers["d"] == nil)
    }

    @Test("Violations in order, with their words")
    func violations() {
        let schema = registry["echo"]!.inputSchema
        #expect(schema.violation(of: ["text": "a", "zeta": 1, "beta": 2]) == "beta: unknown argument.")
        #expect(schema.violation(of: [:]) == "text: required.")
        #expect(schema.violation(of: ["text": nil]) == "text: required.")
        #expect(schema.violation(of: ["text": 3]) == "text: must be a string.")
        #expect(schema.violation(of: ["text": "a", "count": 0]) == "count: must be at least 1.")
        #expect(schema.violation(of: ["text": "a", "count": 4]) == "count: must be at most 3.")
        #expect(schema.violation(of: ["text": "a", "count": .double(1.5)]) == "count: must be an integer.")
        #expect(schema.violation(of: ["text": "a", "mode": "c"]) == "mode: must be one of a, b.")
        #expect(schema.violation(of: ["text": "a", "items": [["label": "x"], [:]]]) == "items[1].label: required.")
        #expect(schema.violation(of: ["text": "a", "items": [nil]]) == "items[0]: must be an object.")
        #expect(schema.violation(of: ["text": "a", "count": 2, "mode": "b"]) == nil)
        #expect(schema.json["additionalProperties"] == false)
        #expect(schema.json["required"] == ["text"])
    }

    @Test("A value of any type has no type and takes a string or an object alike")
    func anyValue() {
        let schema = ToolSchema.object(properties: [("value", .anyValue("A color, or a pair."))], required: ["value"])
        #expect(schema.json["properties"]?["value"] == ["description": "A color, or a pair."])
        #expect(schema.violation(of: ["value": "#FF9500"]) == nil && schema.violation(of: ["value": ["light": "a", "dark": "b"]]) == nil)
        #expect(schema.violation(of: [:]) == "value: required.")
    }
}

@Suite("JSON-RPC")
struct ProtocolTests {
    private let mcp = MCPProtocol(registry: registry, version: "1.0")

    private func reply(_ body: String, versions: [String] = []) async -> MCPReply {
        await mcp.handle(body: Data(body.utf8), protocolVersions: versions)
    }

    private func error(_ body: String) async -> (JSONValue?, String?) {
        guard case .json(let value) = await reply(body) else { return (nil, nil) }
        return (value["error"]?["code"], value["error"]?["message"]?.stringValue)
    }

    @Test("Messages are classified by their kind")
    func classification() async {
        #expect(await error("") == (-32700, "Parse error"))
        #expect(await error("[]") == (-32600, "Invalid Request: batches are not supported"))
        #expect(await error("3") == (-32600, "Invalid Request: the message must be a JSON object"))
        #expect(await error(#"{"jsonrpc":"1.0","method":"ping","id":1}"#) == (-32600, #"Invalid Request: jsonrpc must be "2.0""#))
        #expect(await error(#"{"jsonrpc":"2.0","method":3,"id":1}"#) == (-32600, "Invalid Request: method must be a string"))
        #expect(await reply(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == .accepted)
        #expect(await error(#"{"jsonrpc":"2.0","method":"ping","id":null}"#) == (-32600, "Invalid Request: id must be a string or an integer"))
        #expect(await reply(#"{"jsonrpc":"2.0","id":1,"result":{}}"#) == .accepted)
        #expect(await error(#"{"jsonrpc":"2.0","id":1}"#) == (-32600, "Invalid Request: method must be a string"))
    }

    @Test("initialize negotiates the version; ping; unknown methods; the version header")
    func methods() async {
        guard case .json(let initialized) = await reply(#"{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"2025-11-25"}}"#) else {
            Issue.record("no reply"); return
        }
        #expect(initialized["id"] == "a")
        #expect(initialized["result"]?["protocolVersion"] == "2025-06-18")
        #expect(initialized["result"]?["serverInfo"] == ["name": "hephaestus", "version": "1.0"])
        #expect(await reply(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#) == .json(["jsonrpc": "2.0", "id": 2, "result": [:]]))
        #expect(await error(#"{"jsonrpc":"2.0","id":3,"method":"server/discover"}"#) == (-32601, "Method not found: server/discover"))
        #expect(await reply(#"{"jsonrpc":"2.0","id":4,"method":"ping"}"#, versions: ["2026-07-28"]) == .unsupportedVersion("2026-07-28"))
        #expect(await error(#"{"jsonrpc":"2.0","id":5,"method":"ping","params":[]}"#) == (-32602, "Invalid params: params must be an object"))
        #expect(await error(#"{"jsonrpc":"2.0","id":6,"method":"initialize","params":{}}"#) == (-32602, "Invalid params: protocolVersion must be a string"))
    }

    @Test("Each tool call writes one log line: the tool, the caller and the outcome, never the arguments or the result")
    func callLog() async {
        let lines = LoggedLines()
        let logged = MCPProtocol(registry: registry, version: "1.0", log: { line in lines.add(line) })
        _ = await logged.handle(body: Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{"text":"secret"}}}"#.utf8),
                                protocolVersions: [])
        _ = await logged.handle(body: Data(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"fail"}}"#.utf8), protocolVersions: [])
        let written = lines.all
        #expect(written.count == 2)
        #expect(written[0].hasPrefix("tools/call echo by external: ok in ") && written[0].hasSuffix(" ms"))
        #expect(written[1].hasPrefix("tools/call fail by external: ") && !written[1].contains("ok in"))
        #expect(!written.joined().contains("secret"))
    }

    @Test("tools/list and tools/call: results, tool errors, validation, unknown tools")
    func tools() async {
        guard case .json(let listed) = await reply(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#) else { Issue.record("no reply"); return }
        #expect(listed["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } == ["echo", "fail"])
        guard case .json(let echoed) = await reply(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hi","mode":null}}}"#) else {
            Issue.record("no reply"); return
        }
        #expect(echoed["result"] == ["content": [["type": "text", "text": #"{"text":"hi"}"#]], "isError": false])
        guard case .json(let failed) = await reply(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"fail"}}"#) else {
            Issue.record("no reply"); return
        }
        #expect(failed["result"] == ["content": [["type": "text", "text": "It conflicts."]], "isError": true])
        guard case .json(let invalid) = await reply(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"echo","arguments":{}}}"#) else {
            Issue.record("no reply"); return
        }
        #expect(invalid["result"]?["content"]?.arrayValue?.first?["text"] == "text: required.")
        #expect(await error(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"nope"}}"#) == (-32602, "Unknown tool: nope"))
        #expect(await error(#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"echo","arguments":[]}}"#)
            == (-32602, "Invalid params: arguments must be an object"))
    }
}

@Suite("HTTP")
struct HTTPTests {
    private func head(_ text: String) -> HTTPParser.HeadResult {
        HTTPParser.head(in: Data(text.utf8))
    }

    @Test("Heads parse after empty lines; bad ones are refused")
    func heads() {
        guard case .head(let parsed) = head("\r\nPOST /mcp?x=1 HTTP/1.1\r\nAuthorization: Bearer abc\r\nContent-Length: 2\r\n\r\n{}") else {
            Issue.record("no head"); return
        }
        #expect(parsed.path == "/mcp")
        #expect(parsed.values("authorization") == ["Bearer abc"])
        #expect(head("POST /mcp HTTP/1.1\r\nHost: x\r\n") == .needMore)
        #expect(head("POST /mcp HTTP/2\r\n\r\n") == .failure(.malformed))
        #expect(head("POST /mcp HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n") == .failure(.malformed))
        #expect(head("POST /mcp HTTP/1.1\r\nTransfer-Encoding: gzip\r\n\r\n") == .failure(.malformed))
        #expect(head("POST /mcp HTTP/1.1\r\nX: " + String(repeating: "a", count: 70_000)) == .failure(.headTooLarge))
    }

    @Test("Bodies: Content-Length, chunks, limits")
    func bodies() {
        let text = "POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}\r\n0\r\nX-Trailer: 1\r\n\r\nNEXT"
        guard case .head(let chunkedHead) = head(text) else { Issue.record("no head"); return }
        #expect(HTTPParser.body(of: chunkedHead, in: Data(text.utf8)) == .body(Data("{}".utf8), consumed: text.utf8.count - 4))
        let sized = "POST /mcp HTTP/1.1\r\nContent-Length: 4\r\n\r\n{}"
        guard case .head(let sizedHead) = head(sized) else { Issue.record("no head"); return }
        #expect(HTTPParser.body(of: sizedHead, in: Data(sized.utf8)) == .needMore)
        let large = "POST /mcp HTTP/1.1\r\nContent-Length: 5000000\r\n\r\n"
        guard case .head(let largeHead) = head(large) else { Issue.record("no head"); return }
        #expect(HTTPParser.body(of: largeHead, in: Data(large.utf8)) == .failure(.bodyTooLarge))
    }

    @Test("Bearer tokens: one field, any case, compared whole")
    func tokens() {
        let token = MCPTokens.generate()
        #expect(token.count == 64 && token.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        let tokens = MCPTokens([token])
        #expect(tokens.accepts(token))
        #expect(!tokens.accepts(String(token.dropLast())))
        #expect(MCPTokens.bearer(["bearer   \(token)"]) == token)
        #expect(MCPTokens.bearer(["Basic abc"]) == nil)
        #expect(MCPTokens.bearer(["Bearer a", "Bearer b"]) == nil)
    }
}

@Suite("Server")
struct ServerTests {
    private func post(_ port: Int, path: String = "/mcp", method: String = "POST", token: String?, origin: String? = nil,
                      body: String) async throws -> (Int, String) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        if method == "POST" { request.httpBody = Data(body.utf8) }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as! HTTPURLResponse).statusCode, String(decoding: data, as: UTF8.self))
    }

    @Test("A real listener on 127.0.0.1 answers JSON-RPC with the token, and refuses the rest")
    func listener() async throws {
        let token = MCPTokens.generate()
        let server = MCPServer(protocol: MCPProtocol(registry: registry, version: "1.0"), tokens: MCPTokens([token]))
        await server.start(port: 0)
        guard case .listening(let port) = await server.state else { Issue.record("not listening"); return }
        let ping = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
        let ok = try await post(port, token: token, body: ping)
        #expect(ok.0 == 200)
        #expect(ok.1 == #"{"id":1,"jsonrpc":"2.0","result":{}}"#)
        #expect(try await post(port, token: nil, body: ping).0 == 401)
        let wrong = (token.hasPrefix("0") ? "1" : "0") + token.dropFirst()
        #expect(try await post(port, token: wrong, body: ping).0 == 401)
        #expect(try await post(port, token: token, origin: "https://example.com", body: ping).0 == 403)
        #expect(try await post(port, path: "/other", token: token, body: ping).0 == 404)
        #expect(try await post(port, method: "GET", token: token, body: "").0 == 405)
        #expect(try await post(port, token: token, body: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#).0 == 202)
        await server.stop()
        #expect(await server.state == .stopped)
    }
}

/// The lines a log closure got, from any thread.
private final class LoggedLines: Sendable {
    private let lines = Mutex<[String]>([])
    var all: [String] { lines.withLock { $0 } }
    func add(_ line: String) { lines.withLock { $0.append(line) } }
}
