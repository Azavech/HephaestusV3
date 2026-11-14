import Foundation
import Network
import Synchronization

/// The MCP server: Streamable HTTP limited to POST requests answered with JSON, on 127.0.0.1 only, at `/mcp`
/// (docs/mcp.md). Every tool call runs the operation of a `ToolRegistry`, the function the tool's window
/// calls.
public actor MCPServer {
    public enum State: Sendable, Hashable {
        case stopped
        case listening(port: Int)
        case failed(String)
    }

    public private(set) var state = State.stopped
    /// The state as it changes, for the windows.
    public nonisolated let states: AsyncStream<State>
    private let stateInput: AsyncStream<State>.Continuation

    private let mcp: MCPProtocol
    private let tokens: MCPTokens
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "MCPKit.MCPServer")
    /// Attempts to bind a busy port, one second apart.
    static let bindAttempts = 5

    public init(protocol mcp: MCPProtocol, tokens: MCPTokens) {
        self.mcp = mcp
        self.tokens = tokens
        (states, stateInput) = AsyncStream.makeStream(of: State.self, bufferingPolicy: .bufferingNewest(1))
    }

    /// Listens on 127.0.0.1 at `port` (0: a free port the system picks). A busy port is tried again once a
    /// second, 5 attempts in all; returns once the outcome is known.
    public func start(port: Int) async {
        stop()
        var lastError = ""
        for attempt in 0..<Self.bindAttempts {
            if attempt > 0 { try? await Task.sleep(for: .seconds(1)) }
            switch await bind(port) {
            case .success(let bound):
                set(.listening(port: bound))
                return
            case .failure(let message):
                lastError = message
            }
        }
        set(.failed(lastError))
    }

    /// Closes the listener; connections end with their current request.
    public func stop() {
        listener?.cancel()
        listener = nil
        if case .listening = state { set(.stopped) }
    }

    private func set(_ state: State) {
        self.state = state
        stateInput.yield(state)
    }

    private enum BindResult { case success(Int), failure(String) }

    private func bind(_ port: Int) async -> BindResult {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return .failure("invalid port \(port)") }
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: endpointPort)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            return .failure(String(describing: error))
        }
        let mcp = mcp
        let tokens = tokens
        let queue = queue
        listener.newConnectionHandler = { connection in
            MCPConnection(connection, mcp: mcp, tokens: tokens).start(on: queue)
        }
        let outcome = OneShot<BindResult>()
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                outcome.resolve(.success(Int(listener.port?.rawValue ?? 0)))
            case .failed(let error):
                outcome.resolve(.failure(error.localizedDescription))
                listener.cancel()
                Task { await self?.listenerFailed(error.localizedDescription) }
            case .cancelled:
                outcome.resolve(.failure("cancelled"))
            default:
                break
            }
        }
        listener.start(queue: queue)
        let result = await outcome.value
        if case .success = result { self.listener = listener }
        return result
    }

    private func listenerFailed(_ message: String) {
        guard case .listening = state else { return }
        listener = nil
        set(.failed(message))
    }
}

/// One connection: requests answered one after the other, until the client closes it, a response closes
/// it, or 60 seconds pass without a byte.
private final class MCPConnection: Sendable {
    private let connection: NWConnection
    private let mcp: MCPProtocol
    private let tokens: MCPTokens
    static let idleTimeout: Duration = .seconds(60)

    init(_ connection: NWConnection, mcp: MCPProtocol, tokens: MCPTokens) {
        self.connection = connection
        self.mcp = mcp
        self.tokens = tokens
    }

    func start(on queue: DispatchQueue) {
        connection.start(queue: queue)
        Task { await serve() }
    }

    private func serve() async {
        var buffer = Data()
        while true {
            // The head.
            var head: HTTPHead?
            while head == nil {
                switch HTTPParser.head(in: buffer) {
                case .head(let parsed): head = parsed
                case .failure(let response): return await finish(response)
                case .needMore:
                    guard let more = await receive() else { return connection.cancel() }
                    buffer.append(more)
                }
            }
            guard let head else { return }
            if let rejection = check(head) { return await finish(rejection) }
            if head.values("Expect").contains(where: { $0.lowercased() == "100-continue" }) {
                await send(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8))
            }
            // The body.
            var body: Data?
            var consumed = 0
            while body == nil {
                switch HTTPParser.body(of: head, in: buffer) {
                case .body(let data, let count): body = data; consumed = count
                case .failure(let response): return await finish(response)
                case .needMore:
                    guard let more = await receive() else { return connection.cancel() }
                    buffer.append(more)
                }
            }
            buffer.removeFirst(consumed)
            var response = await answer(head, body: body ?? Data())
            response.closes = response.closes || head.closesConnection
            if response.closes { return await finish(response) }
            await send(response.data)
        }
    }

    /// The checks before the body: Origin, path, method, token (docs/mcp.md › Request handling).
    private func check(_ head: HTTPHead) -> HTTPResponse? {
        if !head.values("Origin").isEmpty { return .originRefused }
        guard head.path == "/mcp" else { return .notFound }
        guard head.method == "POST" else { return .methodNotAllowed }
        guard let token = MCPTokens.bearer(head.values("Authorization")), tokens.accepts(token) else { return .unauthorized }
        return nil
    }

    private func answer(_ head: HTTPHead, body: Data) async -> HTTPResponse {
        switch await mcp.handle(body: body, protocolVersions: head.values("MCP-Protocol-Version")) {
        case .json(let value):
            return HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: value.data)
        case .accepted:
            return HTTPResponse(status: 202)
        case .unsupportedVersion(let version):
            return .rejection(400, "Bad Request: unsupported MCP-Protocol-Version \(version); supported: "
                + MCPProtocol.supportedVersions.joined(separator: ", ") + ".")
        }
    }

    private func finish(_ response: HTTPResponse) async {
        var response = response
        response.closes = true
        await send(response.data)
        connection.cancel()
    }

    private func send(_ data: Data) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: data, completion: .contentProcessed { _ in continuation.resume() })
        }
    }

    /// The next bytes, or nil at the end of the connection or after 60 seconds without any.
    private func receive() async -> Data? {
        let connection = connection
        return await withTaskGroup(of: Data?.self) { group in
            group.addTask {
                await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                        if let data, !data.isEmpty {
                            continuation.resume(returning: data)
                        } else {
                            continuation.resume(returning: nil)
                        }
                        _ = (isComplete, error)
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(for: Self.idleTimeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            if first == nil { connection.cancel() }
            return first
        }
    }
}

/// A value set once, awaited by one caller.
private final class OneShot<Value: Sendable>: Sendable {
    private let state = Mutex<(value: Value?, waiter: CheckedContinuation<Value, Never>?)>((nil, nil))

    func resolve(_ value: Value) {
        let waiter = state.withLock { state -> CheckedContinuation<Value, Never>? in
            guard state.value == nil else { return nil }
            state.value = value
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: value)
    }

    var value: Value {
        get async {
            await withCheckedContinuation { continuation in
                let ready = state.withLock { state -> Value? in
                    if state.value == nil { state.waiter = continuation }
                    return state.value
                }
                if let ready { continuation.resume(returning: ready) }
            }
        }
    }
}
