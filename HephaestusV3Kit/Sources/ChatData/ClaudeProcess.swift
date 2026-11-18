import Darwin
import ExternalTools
import FileStorage
import Foundation
import MCPKit
import Synchronization

/// How a chat's CLI process is started (docs/architecture.md › ChatData › Launch). Nothing of it is text
/// written for Claude: no system prompt, no hook, no skill.
public struct ChatLaunch: Sendable, Hashable {
    public var cliPath: String
    public var chatID: String
    /// True once the session exists: `--resume`; else `--session-id`.
    public var resume: Bool
    public var model: String
    public var effort: Effort
    /// `<data folder>/Runtime/mcp/<chat id>.json`.
    public var mcpConfig: URL
    /// The names of the app's MCP tools, which Claude may call without the CLI asking: the app asks itself
    /// before a change, as the user's permissions say.
    public var tools: [String]
    /// The CLI's own tools Claude gets: the file tools (`ClaudeFileTools.tools(edits:)`), which the CLI asks
    /// about before a call, the app answering (`ClaudeFileTools.decision`).
    public var fileTools: [String]
    /// The project's folder.
    public var workingDirectory: String
    /// The login shell's environment, without `HEPHAESTUS_*` variables.
    public var environment: [String: String]

    public init(cliPath: String, chatID: String, resume: Bool, model: String, effort: Effort, mcpConfig: URL, tools: [String],
                fileTools: [String] = [], workingDirectory: String, environment: [String: String], pluginDir: URL? = nil) {
        self.cliPath = cliPath
        self.chatID = chatID
        self.resume = resume
        self.model = model
        self.effort = effort
        self.mcpConfig = mcpConfig
        self.tools = tools
        self.fileTools = fileTools
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.pluginDir = pluginDir
    }

    /// One argument per element, no shell involved. `--tools` gives Claude the file tools alone of the CLI's own
    /// (no shell, no web, no agents); `--strict-mcp-config` leaves it the app's server alone.
    public var arguments: [String] {
        [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
            resume ? "--resume" : "--session-id", chatID,
            "--model", model,
            "--effort", effort.rawValue,
            "--permission-mode", "manual",
            "--permission-prompt-tool", "stdio",
            "--tools", fileTools.joined(separator: ","),
            "--strict-mcp-config",
            "--mcp-config", mcpConfig.path,
            "--allowedTools", tools.map { "mcp__\(MCPProtocol.serverName)__\($0)" }.joined(separator: ","),
        ] + (pluginDir.map { ["--plugin-dir", $0.path] } ?? [])
    }

    /// The CLI's time limit for a tool call, in milliseconds: a call waits while the user decides on its card.
    public static let toolTimeout = "1800000"

    public var request: ProcessRequest {
        var environment = ShellEnvironment.forChildren(environment)
        environment["MCP_TOOL_TIMEOUT"] = Self.toolTimeout
        return ProcessRequest(executable: cliPath, arguments: arguments, environment: environment, currentDirectory: workingDirectory,
                              standardInput: .pipe, standardOutput: .pipe, standardError: .pipe)
    }

    /// The launch as the log's first line shows it: each argument quoted when it holds anything but letters,
    /// digits and `-_./:=,@+%`.
    public var logLine: String {
        ([cliPath] + arguments).map { argument in
            let plain = !argument.isEmpty && argument.allSatisfy { $0.isLetter || $0.isNumber || "-_./:=,@+%".contains($0) }
            return plain ? argument : "'" + argument.replacing("'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }

    /// The app's internal skills, as a plugin the chat can call them from (`--plugin-dir`); nil leaves them out.
    public var pluginDir: URL?

    /// The MCP configuration file: the app's server on 127.0.0.1 with the chat's token.
    public static func mcpConfiguration(port: Int, token: String) -> Data {
        JSONValue.object(["mcpServers": [MCPProtocol.serverName: [
            "type": "http", "url": .string("http://127.0.0.1:\(port)/mcp"), "headers": ["Authorization": .string("Bearer \(token)")],
        ]]]).data
    }
}

/// The lines the app writes to a chat's CLI (docs/architecture.md › ChatData › Protocol).
public enum ClaudeInput {
    /// A user message: its text, with the item it carries on the last line (docs/ui/chat.md › What Claude
    /// receives). `uuid` is the user item's id.
    /// `images` come first, each a base-64 image block, as the Messages API takes them.
    public static func message(_ text: String, images: [ClaudeImage] = [], uuid: String) -> Data {
        let blocks: [JSONValue] = images.map { image in
            ["type": "image", "source": ["type": "base64", "media_type": .string(image.mimeType), "data": .string(image.data.base64EncodedString())]]
        }
        return line(["type": "user", "message": ["role": "user", "content": .array(blocks + [["type": "text", "text": .string(text)]])],
                     "uuid": .string(uuid)])
    }

    public static func control(_ id: String, _ request: JSONValue) -> Data {
        line(["type": "control_request", "request_id": .string(id), "request": request])
    }

    public static func allow(_ requestID: String, input: JSONValue) -> Data {
        line(["type": "control_response", "response": ["subtype": "success", "request_id": .string(requestID),
                                                       "response": ["behavior": "allow", "updatedInput": input]]])
    }

    public static func deny(_ requestID: String, message: String) -> Data {
        line(["type": "control_response", "response": ["subtype": "success", "request_id": .string(requestID),
                                                       "response": ["behavior": "deny", "message": .string(message)]]])
    }

    public static func unsupported(_ requestID: String, subtype: String) -> Data {
        line(["type": "control_response", "response": ["subtype": "error", "request_id": .string(requestID),
                                                       "error": .string("Unsupported control request: \(subtype)")]])
    }

    private static func line(_ value: JSONValue) -> Data {
        var data = value.data
        data.append(UInt8(ascii: "\n"))
        return data
    }

    /// The text Claude receives for a message: the user's text, a blank line, then `Attached: …` for the item
    /// its chip showed. V3 writes it; it describes the item and says nothing of how to work.
    public static func text(_ message: String, carrying references: [ChatItemReference]) -> String {
        let lines = references.map(attachedLine)
        return lines.isEmpty ? message : message + "\n\n" + lines.joined(separator: "\n")
    }

    /// `Attached: ticket ORD-142 of project ORD`.
    static func attachedLine(_ reference: ChatItemReference) -> String {
        let project = reference.projectID
        let seen = reference.environment.map { ", as seen in \($0)" } ?? ""
        let focus = reference.focus
        func after(_ prefix: String) -> String? { focus.hasPrefix(prefix) ? String(focus.dropFirst(prefix.count)) : nil }
        let item: String = switch reference.tool {
        case ChatItemReference.projectTool: "project \(project)"
        case "tickets": "ticket \(focus) of project \(project)"
        case "serviceMap":
            if let request = after("request:") { "request \(request) of project \(project)\(seen)" }
            else { "service \(after("service:") ?? focus) of project \(project)\(seen)" }
        case "builds":
            if let tag = after("release:") { "release \(tag) of project \(project)" } else { "run \(focus) of project \(project)" }
        case "contracts": "operation \(focus) of project \(project)"
        case ChatItemReference.fileTool: "file \(focus)"
        default: "\(reference.tool) item \(focus) of project \(project)"
        }
        return "Attached: \(item)"
    }
}

/// A chat's running CLI, as the session drives it. Tests replay recorded streams through a fake one.
public protocol ClaudeConnection: AnyObject, Sendable {
    /// Standard output, one line at a time, without its LF.
    var lines: AsyncStream<Data> { get }
    /// Writes to standard input; nothing once it is closed.
    func write(_ data: Data)
    func closeInput()
    /// Signals the process group.
    func signal(_ signal: Int32)
    var hasExited: Bool { get }
    func waitForExit() async -> ProcessTermination
    /// The last lines the process wrote on standard error, oldest first.
    var errorLines: [String] { get }
}

/// Starts the CLI: a chat's process, or the probe that reads the model list.
public protocol ClaudeLaunching: Sendable {
    /// Starts the process; standard error goes to `log`, after a line with `logLine`.
    func launch(_ request: ProcessRequest, log: URL?, logLine: String) throws -> any ClaudeConnection
}

/// Starts real processes, each the leader of its own process group.
public struct SystemClaudeLauncher: ClaudeLaunching {
    public init() {}

    public func launch(_ request: ProcessRequest, log: URL?, logLine: String) throws -> any ClaudeConnection {
        SystemClaudeConnection(try ChildProcess.spawn(request), log: log, launchLine: logLine)
    }
}

/// A real CLI: its pipes read on threads of their own, standard error appended to the chat's log.
final class SystemClaudeConnection: ClaudeConnection {
    let lines: AsyncStream<Data>
    private let process: ChildProcess
    private let writes = DispatchQueue(label: "ClaudeConnection.write")
    private let input: Mutex<FileHandle?>
    private let errors = Mutex<[String]>([])

    /// A line longer than this is dropped.
    static let maximumLine = 64 * 1024 * 1024
    /// The log is emptied at launch once larger than this.
    static let maximumLog = 10 * 1024 * 1024

    init(_ process: ChildProcess, log: URL?, launchLine: String) {
        self.process = process
        input = Mutex(process.standardInput)
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
        lines = stream
        if let output = process.standardOutput {
            Self.read(output, name: "ClaudeConnection.stdout") { buffer, chunk in
                buffer.append(chunk)
                while let end = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = buffer[buffer.startIndex..<end]
                    if !line.isEmpty, line.count <= Self.maximumLine { continuation.yield(Data(line)) }
                    buffer.removeSubrange(buffer.startIndex...end)
                }
                if buffer.count > Self.maximumLine { buffer.removeAll() }
            } finished: { buffer in
                if !buffer.isEmpty, buffer.count <= Self.maximumLine { continuation.yield(buffer) }
                continuation.finish()
            }
        } else {
            continuation.finish()
        }
        let logHandle = log.flatMap { Self.openLog($0, launchLine: launchLine) }
        if let errorOutput = process.standardError {
            Self.read(errorOutput, name: "ClaudeConnection.stderr") { [self] buffer, chunk in
                try? logHandle?.write(contentsOf: chunk)
                buffer.append(chunk)
                while let end = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let text = String(decoding: buffer[buffer.startIndex..<end], as: UTF8.self)
                    errors.withLock { lines in
                        lines.append(text)
                        if lines.count > 50 { lines.removeFirst(lines.count - 50) }
                    }
                    buffer.removeSubrange(buffer.startIndex...end)
                }
            } finished: { [self] buffer in
                if !buffer.isEmpty { errors.withLock { $0.append(String(decoding: buffer, as: UTF8.self)) } }
                try? logHandle?.close()
            }
        }
    }

    func write(_ data: Data) {
        writes.async { [self] in
            input.withLock { handle in
                do { try handle?.write(contentsOf: data) } catch { handle = nil }
            }
        }
    }

    func closeInput() {
        writes.async { [self] in
            input.withLock { handle in
                try? handle?.close()
                handle = nil
            }
        }
    }

    func signal(_ signal: Int32) { process.signalGroup(signal) }
    var hasExited: Bool { process.hasExited }
    func waitForExit() async -> ProcessTermination { await process.waitForExit() }
    var errorLines: [String] { errors.withLock { $0 } }

    /// Reads a pipe with blocking reads on a thread of its own until end of file.
    private static func read(_ handle: FileHandle, name: String, chunk: @escaping @Sendable (inout Data, Data) -> Void,
                             finished: @escaping @Sendable (Data) -> Void) {
        let thread = Thread {
            let descriptor = handle.fileDescriptor
            var buffer = Data()
            var bytes = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                if count > 0 {
                    chunk(&buffer, Data(bytes[0..<count]))
                } else if count < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            finished(buffer)
            withExtendedLifetime(handle) {}
        }
        thread.name = name
        thread.start()
    }

    /// The chat's log, opened for appending after the launch line; emptied first once over 10 MB.
    private static func openLog(_ url: URL, launchLine: String) -> FileHandle? {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if size > maximumLog || !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data("--- \(ISO8601DateFormatter().string(from: Date())) launch: \(launchLine) ---\n".utf8))
        return handle
    }
}
