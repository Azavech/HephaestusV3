import Darwin
import Foundation
import Synchronization

/// Runs short-lived tools and collects their output. The app uses `SystemProcessRunner`; tests use a
/// fake that answers from a script, so they never start the user's tools.
public protocol ProcessRunning: Sendable {
    /// Runs the request with standard output and error piped and `input` on standard input (none:
    /// `/dev/null`). When `timeout` passes first, the process group gets SIGTERM, then SIGKILL 2 s
    /// later, and the result says `timedOut`. Throws `ChildProcessError` when the process can't start.
    func run(_ request: ProcessRequest, input: Data?, timeout: Duration?) async throws -> ProcessResult
}

extension ProcessRunning {
    public func run(_ request: ProcessRequest, timeout: Duration?) async throws -> ProcessResult {
        try await run(request, input: nil, timeout: timeout)
    }
}

/// Starts real processes, each the leader of its own process group, and keeps the running ones, so the
/// app can end them when it quits.
public final class SystemProcessRunner: ProcessRunning {
    /// The runner of the app.
    public static let shared = SystemProcessRunner()

    private let running = Mutex<[pid_t: ChildProcess]>([:])

    public init() {}

    public func run(_ request: ProcessRequest, input: Data?, timeout: Duration?) async throws -> ProcessResult {
        let result = try await ChildProcessRunner.run(request, input: input, timeout: timeout) { process in
            self.running.withLock { $0[process.pid] = process }
        }
        running.withLock { $0 = $0.filter { !$0.value.hasExited } }
        return result
    }

    /// The processes still running.
    public var runningCount: Int {
        running.withLock { $0.values.filter { !$0.hasExited }.count }
    }

    /// Sends SIGTERM to the process group of every running process: what they started ends with them.
    public func terminateAll() {
        let processes = running.withLock { running in
            defer { running = [:] }
            return Array(running.values)
        }
        for process in processes where !process.hasExited {
            process.signalGroup(SIGTERM)
        }
    }
}
