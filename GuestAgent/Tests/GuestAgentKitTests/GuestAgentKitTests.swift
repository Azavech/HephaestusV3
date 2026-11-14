import Darwin
import Foundation
import Testing
@testable import GuestAgentKit

/// docs/guest-agent.md: the agent's session over a socket pair, in one process, the host side written with the
/// agent's own frames. Commands run through `/bin/sh -c`, so no test reads the shell files of the user running it,
/// and never as root. The methods that need the Accessibility or Screen Recording permission aren't called.
@Suite("Guest agent")
struct GuestAgentKitTests {
    /// A host's end of a session.
    final class Host: @unchecked Sendable {
        let descriptor: Int32
        private var nextID = 1

        init(_ descriptor: Int32) { self.descriptor = descriptor }

        /// One request and its response: the response's JSON and data.
        func request(_ method: String, _ params: [String: Any] = [:], data: Data = Data()) throws -> (json: [String: Any], data: Data) {
            defer { nextID += 1 }
            try AgentFrame(json: ["type": "request", "id": nextID, "method": method, "params": params], data: data).write(to: descriptor)
            let frame = try #require(try AgentFrame.read(from: descriptor))
            #expect(frame.json["id"] as? Int == nextID)
            return (frame.json, frame.data)
        }

        func result(_ method: String, _ params: [String: Any] = [:], data: Data = Data()) throws -> [String: Any] {
            try #require(request(method, params, data: data).json["result"] as? [String: Any])
        }

        func failure(_ method: String, _ params: [String: Any] = [:]) throws -> String? {
            try request(method, params).json["error"] as? String
        }
    }

    /// Runs `body` with the host's end of a session served on its own thread; returns the hello too.
    static func withAgent<T>(_ body: (Host, [String: Any]) throws -> T) throws -> T {
        var pair: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        var handlers = AgentSession.systemHandlers
        handlers["exec"] = { params, _ in try AgentCommands.exec(params, shell: ["/bin/sh", "-c"], rootKill: nil) }
        let agent = pair[1]
        Thread {
            AgentSession(input: agent, output: agent, handlers: handlers).run()
            close(agent)
        }.start()
        defer { close(pair[0]) }
        let hello = try #require(try AgentFrame.read(from: pair[0]))
        return try body(Host(pair[0]), hello.json)
    }

    static func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("GuestAgentKitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test("The agent starts with its hello of protocol 1, and status gives the same object")
    func hello() throws {
        try Self.withAgent { (host: Host, hello: [String: Any]) throws in
            #expect(hello["type"] as? String == "hello")
            #expect(hello["protocol"] as? Int == 1)
            let status = try #require(hello["status"] as? [String: Any])
            #expect(status["version"] as? String == "3.0")
            #expect(status["user"] as? String == NSUserName())
            #expect(["disabled", "enabled", "unknown"].contains(status["sip"] as? String ?? ""))
            let again = try host.result("status")
            #expect(again["user"] as? String == NSUserName())
        }
    }

    @Test("The SIP state is read from the first line of csrutil status")
    func sipState() {
        #expect(AgentStatus.sipState(fromOutput: "System Integrity Protection status: disabled.\n") == "disabled")
        #expect(AgentStatus.sipState(fromOutput: "System Integrity Protection status: enabled.\n") == "enabled")
        #expect(AgentStatus.sipState(fromOutput: "System Integrity Protection status: unknown (Custom Configuration).\n") == "unknown")
        #expect(AgentStatus.sipState(fromOutput: "") == "unknown")
    }

    @Test("exec returns the exit status and outputs, kills at the timeout, cuts outputs at 1 MB and checks its params")
    func exec() throws {
        try Self.withAgent { (host: Host, _: [String: Any]) throws in
            let echo = try host.result("exec", ["command": "echo out; echo err >&2; exit 3"])
            #expect(echo["exitStatus"] as? Int == 3)
            #expect(echo["stdout"] as? String == "out\n")
            #expect(echo["stderr"] as? String == "err\n")
            #expect(echo["timedOut"] as? Bool == false)

            let slow = try host.result("exec", ["command": "sleep 30", "timeout": 0.3])
            #expect(slow["timedOut"] as? Bool == true)
            #expect(slow["exitStatus"] as? Int == 128 + Int(SIGKILL))

            let large = try host.result("exec", ["command": "yes | head -c 1100000"])
            #expect(large["truncated"] as? Bool == true)
            #expect((large["stdout"] as? String)?.count == 1_048_576)

            #expect(try host.failure("exec", ["command": ""]) == "command: use a command that is not empty.")
            #expect(try host.failure("exec") == "command: use a string.")
            #expect(try host.failure("exec", ["command": "true", "asRoot": "yes"]) == "asRoot: use true or false.")
        }
    }

    @Test("The file methods write, read, stat, list and make folders as the account")
    func files() throws {
        let folder = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Self.withAgent { (host: Host, _: [String: Any]) throws in
            let file = folder.appendingPathComponent("nested/dir/file.bin").path
            let bytes = Data((0..<200).map { UInt8($0) })
            _ = try host.result("writeFile", ["path": file, "mode": 0o755], data: bytes.prefix(120))
            _ = try host.result("writeFile", ["path": file, "offset": 120], data: bytes.suffix(80))
            #expect(try Data(contentsOf: URL(fileURLWithPath: file)) == bytes)

            let status = try host.result("stat", ["path": file])
            #expect(status["exists"] as? Bool == true && status["size"] as? Int == 200 && status["mode"] as? Int == 0o755)
            #expect(try host.result("stat", ["path": file + ".none"])["exists"] as? Bool == false)

            let first = try host.request("readFile", ["path": file, "length": 150])
            #expect(first.data == bytes.prefix(150))
            #expect((first.json["result"] as? [String: Any])?["eof"] as? Bool == false)
            let rest = try host.request("readFile", ["path": file, "offset": 150])
            #expect(rest.data == bytes.suffix(50))

            _ = try host.result("makeDirectory", ["path": folder.appendingPathComponent("made/here").path])
            let entries = try #require(try host.result("list", ["path": folder.path])["entries"] as? [[String: Any]])
            #expect(entries.compactMap { $0["name"] as? String } == ["made", "nested"])
            #expect(try host.failure("readFile", ["path": "relative/file"]) == "path: use an absolute path or a path starting with ~/.")
        }
    }

    @Test("An unknown method fails with its name, setEnv among them")
    func unknown() throws {
        try Self.withAgent { (host: Host, _: [String: Any]) throws in
            #expect(try host.failure("noSuchMethod") == "Unknown method noSuchMethod.")
            #expect(try host.failure("setEnv", ["name": "X", "value": "1"]) == "Unknown method setEnv.")
        }
    }
}
