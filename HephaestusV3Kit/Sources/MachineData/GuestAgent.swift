import Darwin
import Foundation
import MCPKit

/// One frame of the guest agent's protocol (docs/data.md › Virtual machines › Guest agent): the lengths of the
/// JSON part and of the data part, 4 bytes each, big-endian, then one JSON object and the raw bytes.
public struct GuestAgentFrame: Sendable, Hashable {
    public var json: [String: JSONValue]
    /// A PNG, a part of a file; empty for most frames.
    public var data: Data

    public static let maximumJSONLength = 16_777_216
    public static let maximumDataLength = 67_108_864

    public init(json: [String: JSONValue], data: Data = Data()) {
        self.json = json
        self.data = data
    }

    public func encoded() throws(GuestAgentError) -> Data {
        guard let body = try? JSONSerialization.data(withJSONObject: JSONValue.object(json).foundation, options: [.sortedKeys, .withoutEscapingSlashes]),
              (1...Self.maximumJSONLength).contains(body.count), data.count <= Self.maximumDataLength else {
            throw .protocolError("a frame is over the limits of the protocol")
        }
        var bytes = Data(capacity: 8 + body.count + data.count)
        Self.append(UInt32(body.count), to: &bytes)
        Self.append(UInt32(data.count), to: &bytes)
        bytes.append(body)
        bytes.append(data)
        return bytes
    }

    /// Reads one frame, blocking until it is complete. Nil when the stream ends before a frame starts.
    public static func read(from descriptor: Int32) throws(GuestAgentError) -> GuestAgentFrame? {
        guard let header = try readBytes(8, from: descriptor, endAllowed: true) else { return nil }
        let jsonLength = Int(length(header, at: 0))
        let dataLength = Int(length(header, at: 4))
        guard (1...maximumJSONLength).contains(jsonLength), dataLength <= maximumDataLength else {
            throw .protocolError("a frame is over the limits of the protocol")
        }
        guard let body = try readBytes(jsonLength, from: descriptor, endAllowed: false) else { throw .disconnected }
        let data = dataLength == 0 ? Data() : try readBytes(dataLength, from: descriptor, endAllowed: false) ?? Data()
        return try decode(body: body, data: data)
    }

    static func decode(body: Data, data: Data) throws(GuestAgentError) -> GuestAgentFrame {
        guard let object = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]),
              case .object(let json) = JSONValue(foundation: object) else {
            throw .protocolError("the JSON part of a frame is not an object")
        }
        return GuestAgentFrame(json: json, data: data)
    }

    public func write(to descriptor: Int32) throws(GuestAgentError) {
        let bytes = try encoded()
        let failed = bytes.withUnsafeBytes { buffer -> Bool in
            guard var pointer = buffer.baseAddress else { return false }
            var remaining = buffer.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, pointer, remaining)
                if count < 0 {
                    if errno == EINTR { continue }
                    return true
                }
                remaining -= count
                pointer = pointer.advanced(by: count)
            }
            return false
        }
        if failed { throw .disconnected }
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    private static func length(_ header: Data, at offset: Int) -> UInt32 {
        header.subdata(in: offset..<(offset + 4)).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func readBytes(_ count: Int, from descriptor: Int32, endAllowed: Bool) throws(GuestAgentError) -> Data? {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let received = data.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!.advanced(by: offset), count - offset) }
            if received < 0 {
                if errno == EINTR { continue }
                throw .disconnected
            }
            if received == 0 {
                if offset == 0, endAllowed { return nil }
                throw .disconnected
            }
            offset += received
        }
        return data
    }
}

public enum GuestAgentError: Error, LocalizedError, Sendable, Hashable {
    case disconnected
    case timedOut(method: String)
    /// The agent's message.
    case failed(message: String)
    case protocolError(String)

    public var errorDescription: String? {
        switch self {
        case .disconnected: "The guest agent is not connected."
        case .timedOut(let method): "The guest agent did not answer \(method) in time."
        case .failed(let message): message
        case .protocolError(let reason): "The guest agent's connection failed: \(reason)."
        }
    }
}

/// What the agent reports about itself and its guest: its hello, and the result of `status`.
public struct GuestAgentStatus: Sendable, Hashable {
    public enum SIP: String, Sendable, Hashable { case disabled, enabled, unknown }

    public var version: String
    public var sip: SIP
    /// The short name of the account the agent runs as.
    public var user: String
    public var osVersion: String
    public var osBuild: String
    public var accessibility: Bool
    public var screenRecording: Bool

    public init(version: String, sip: SIP, user: String = "", osVersion: String = "", osBuild: String = "",
                accessibility: Bool = false, screenRecording: Bool = false) {
        self.version = version
        self.sip = sip
        self.user = user
        self.osVersion = osVersion
        self.osBuild = osBuild
        self.accessibility = accessibility
        self.screenRecording = screenRecording
    }

    /// Nil without a `version`.
    public init?(json: JSONValue) {
        guard let object = json.objectValue, let version = object["version"]?.stringValue else { return nil }
        self.init(version: version, sip: object["sip"]?.stringValue.flatMap(SIP.init(rawValue:)) ?? .unknown,
                  user: object["user"]?.stringValue ?? "", osVersion: object["osVersion"]?.stringValue ?? "",
                  osBuild: object["osBuild"]?.stringValue ?? "", accessibility: object["accessibility"]?.boolValue ?? false,
                  screenRecording: object["screenRecording"]?.boolValue ?? false)
    }
}

/// The agent's answer to one request: its `result` and the data part of its frame.
public struct GuestAgentResponse: Sendable, Hashable {
    public var result: [String: JSONValue]
    public var data: Data

    public init(result: [String: JSONValue] = [:], data: Data = Data()) {
        self.result = result
        self.data = data
    }
}

/// The host side of one connection of the agent: it reads the hello, sends requests and gives each its
/// response. The descriptor is read on a thread of its own and written on a serial queue. The agent serves one
/// request at a time, so the host writes one at a time too, the next once the agent has answered: a request
/// whose caller gave up while it waited its turn (timed out or cancelled) is never written, so it can't run in
/// the guest later. When the connection ends, every waiting request fails with `disconnected`, `closer` runs,
/// then `onClose`. Only the end of the read loop closes the descriptor.
public final class GuestAgentConnection: @unchecked Sendable {
    public static let protocolVersion = 1
    public static let helloTimeout: Duration = .seconds(10)

    private let descriptor: Int32
    private let closer: @Sendable () -> Void
    private let onClose: @Sendable () -> Void
    private let writeQueue = DispatchQueue(label: "fr.azavech.hephaestusv3.guest-agent.write")
    private let lock = NSLock()
    private var currentStatus: GuestAgentStatus?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<GuestAgentResponse, any Error>] = [:]
    /// The requests not written yet, in the order they were made.
    private var queue: [(id: Int, frame: GuestAgentFrame)] = []
    /// The request the agent has and hasn't answered yet, whether or not its caller still waits.
    private var inFlight: Int?
    private var hello: CheckedContinuation<GuestAgentStatus, any Error>?
    private var isFinished = false

    /// The hello's status, replaced by each `refreshStatus()`.
    public var status: GuestAgentStatus {
        lock.withLock { currentStatus } ?? GuestAgentStatus(version: "", sip: .unknown)
    }

    private init(descriptor: Int32, closer: @escaping @Sendable () -> Void, onClose: @escaping @Sendable () -> Void) {
        self.descriptor = descriptor
        self.closer = closer
        self.onClose = onClose
    }

    /// Takes a connected descriptor and waits for the hello; throws when it doesn't come in time or isn't a
    /// hello of this protocol, the descriptor then closed too.
    public static func open(descriptor: Int32, helloTimeout: Duration = GuestAgentConnection.helloTimeout,
                            closer: @escaping @Sendable () -> Void, onClose: @escaping @Sendable () -> Void = {}) async throws -> GuestAgentConnection {
        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
        let connection = GuestAgentConnection(descriptor: descriptor, closer: closer, onClose: onClose)
        let timeout = Task {
            try? await Task.sleep(for: helloTimeout)
            if !Task.isCancelled { connection.close() }
        }
        defer { timeout.cancel() }
        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<GuestAgentStatus, any Error>) in
            connection.lock.withLock { connection.hello = continuation }
            let thread = Thread { connection.readLoop() }
            thread.name = "guest-agent-read"
            thread.stackSize = 8 << 20
            thread.start()
        }
        return connection
    }

    /// Sends one request and waits for its response: `failed` with the agent's message, `timedOut` after
    /// `timeout`, `disconnected` when the connection ends first.
    public func request(_ method: String, params: [String: JSONValue] = [:], data: Data = Data(),
                        timeout: Duration = .seconds(60)) async throws -> GuestAgentResponse {
        let id = lock.withLock { () -> Int in
            defer { nextID += 1 }
            return nextID
        }
        let frame = GuestAgentFrame(json: ["type": "request", "id": .int(id), "method": .string(method), "params": .object(params)], data: data)
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { self?.fail(id, with: GuestAgentError.timedOut(method: method)) }
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<GuestAgentResponse, any Error>) in
                let finished = lock.withLock { () -> Bool in
                    if isFinished { return true }
                    pending[id] = continuation
                    queue.append((id, frame))
                    return false
                }
                if finished {
                    continuation.resume(throwing: GuestAgentError.disconnected)
                    return
                }
                sendNext()
            }
        } onCancel: {
            fail(id, with: CancellationError())
        }
    }

    @discardableResult
    public func refreshStatus() async throws -> GuestAgentStatus {
        let response = try await request("status", timeout: .seconds(15))
        guard let status = GuestAgentStatus(json: .object(response.result)) else {
            throw GuestAgentError.protocolError("the status of the agent cannot be read")
        }
        lock.withLock { currentStatus = status }
        return status
    }

    /// `/sbin/shutdown -h now` as root.
    public func shutDownGuest() async throws {
        let response = try await request("exec", params: ["command": "/sbin/shutdown -h now", "asRoot": true, "timeout": 20], timeout: .seconds(30))
        if let status = response.result["exitStatus"]?.intValue, status != 0 {
            let message = response.result["stderr"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw GuestAgentError.failed(message: message.isEmpty ? "The guest could not be shut down." : message)
        }
    }

    public func close() {
        let woken = lock.withLock { () -> Bool in
            guard !isFinished else { return true }
            return shutdown(descriptor, SHUT_RDWR) == 0
        }
        if !woken { failWaiting(with: GuestAgentError.disconnected) }
    }

    private func readLoop() {
        do {
            guard let first = try GuestAgentFrame.read(from: descriptor) else { throw GuestAgentError.disconnected }
            guard first.json["type"]?.stringValue == "hello", first.json["protocol"] == .int(Self.protocolVersion),
                  let status = first.json["status"].flatMap(GuestAgentStatus.init(json:)) else {
                throw GuestAgentError.protocolError("the agent did not start with the hello of protocol \(Self.protocolVersion)")
            }
            let waiting = lock.withLock { () -> CheckedContinuation<GuestAgentStatus, any Error>? in
                currentStatus = status
                defer { hello = nil }
                return hello
            }
            waiting?.resume(returning: status)
            while let frame = try GuestAgentFrame.read(from: descriptor) {
                receive(frame)
            }
            readEnded(with: GuestAgentError.disconnected)
        } catch {
            readEnded(with: error)
        }
    }

    /// Writes the next request whose caller still waits, when the agent has none to answer.
    private func sendNext() {
        let next = lock.withLock { () -> (id: Int, frame: GuestAgentFrame)? in
            guard inFlight == nil, !isFinished else { return nil }
            while !queue.isEmpty {
                let request = queue.removeFirst()
                if pending[request.id] != nil {
                    inFlight = request.id
                    return request
                }
            }
            return nil
        }
        guard let next else { return }
        writeQueue.async { [self] in
            guard !lock.withLock({ isFinished }) else {
                fail(next.id, with: GuestAgentError.disconnected)
                return
            }
            do {
                try next.frame.write(to: descriptor)
            } catch {
                lock.withLock { if inFlight == next.id { inFlight = nil } }
                fail(next.id, with: error)
                sendNext()
            }
        }
    }

    private func receive(_ frame: GuestAgentFrame) {
        guard frame.json["type"]?.stringValue == "response", let id = frame.json["id"]?.intValue else { return }
        let continuation = lock.withLock { () -> CheckedContinuation<GuestAgentResponse, any Error>? in
            if inFlight == id { inFlight = nil }
            return pending.removeValue(forKey: id)
        }
        sendNext()
        guard let continuation else { return }
        if let message = frame.json["error"]?.stringValue {
            continuation.resume(throwing: GuestAgentError.failed(message: message))
        } else {
            continuation.resume(returning: GuestAgentResponse(result: frame.json["result"]?.objectValue ?? [:], data: frame.data))
        }
    }

    private func fail(_ id: Int, with error: any Error) {
        lock.withLock { pending.removeValue(forKey: id) }?.resume(throwing: error)
    }

    private func failWaiting(with error: any Error) {
        let (waitingHello, waiting) = lock.withLock {
            () -> (CheckedContinuation<GuestAgentStatus, any Error>?, [CheckedContinuation<GuestAgentResponse, any Error>]) in
            guard !isFinished else { return (nil, []) }
            isFinished = true
            defer {
                hello = nil
                pending.removeAll()
                queue.removeAll()
                inFlight = nil
            }
            return (hello, Array(pending.values))
        }
        waitingHello?.resume(throwing: error)
        for continuation in waiting { continuation.resume(throwing: GuestAgentError.disconnected) }
    }

    private func readEnded(with error: any Error) {
        failWaiting(with: error)
        writeQueue.async { [closer, onClose] in
            closer()
            onClose()
        }
    }
}
