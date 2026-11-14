import Darwin
import Foundation
import Synchronization

/// How a child process ended.
public enum ProcessTermination: Hashable, Sendable {
    case exited(Int32)
    case signaled(Int32)

    public var isSuccess: Bool { self == .exited(0) }
}

public enum ChildProcessError: Error, Equatable, Sendable, CustomStringConvertible {
    case spawnFailed(executable: String, errno: Int32)
    case pipeFailed(errno: Int32)

    public var description: String {
        switch self {
        case let .spawnFailed(executable, code):
            return "cannot start \(executable): \(String(cString: strerror(code)))"
        case let .pipeFailed(code):
            return "cannot create a pipe: \(String(cString: strerror(code)))"
        }
    }
}

/// What to start (docs/architecture.md › Child processes): the caller passes the environment, already
/// without `HEPHAESTUS_*` variables (`ShellEnvironment.forChildren`), and the working directory.
public struct ProcessRequest: Sendable, Hashable {
    public enum Input: Sendable, Hashable { case null, pipe }
    public enum Output: Sendable, Hashable { case null, pipe }

    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var currentDirectory: String?
    public var standardInput: Input
    public var standardOutput: Output
    public var standardError: Output

    public init(executable: String, arguments: [String] = [], environment: [String: String],
                currentDirectory: String? = nil, standardInput: Input = .null,
                standardOutput: Output = .pipe, standardError: Output = .pipe) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.currentDirectory = currentDirectory
        self.standardInput = standardInput
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

/// A child process started with `posix_spawn` as the leader of a new process group
/// (`POSIX_SPAWN_SETPGROUP`), so that a signal sent to the group reaches what it started.
///
/// Each pipe end this process keeps has exactly one owner, its `FileHandle`, which closes it
/// once: with `close()` or when the last reference to the handle goes away. Readers keep a
/// reference to their handle until end of file, so a descriptor is never closed while a read
/// may use it, and nothing else closes these descriptors.
public final class ChildProcess: Sendable {
    public let pid: pid_t
    /// Write end of standard input when the request asked for a pipe. Writing to it after the
    /// child closed its end fails with `EPIPE` and raises no `SIGPIPE`.
    public let standardInput: FileHandle?
    /// Read end of standard output when the request asked for a pipe.
    public let standardOutput: FileHandle?
    /// Read end of standard error when the request asked for a pipe.
    public let standardError: FileHandle?

    private let waiter: ExitWaiter

    private init(pid: pid_t, standardInput: FileHandle?, standardOutput: FileHandle?, standardError: FileHandle?) {
        self.pid = pid
        self.standardInput = standardInput
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.waiter = ExitWaiter(pid: pid)
    }

    /// Starts the process. Its process group id equals its pid.
    ///
    /// The pipes are plain descriptors until the spawn succeeded: a failure closes each of them
    /// exactly once, and only a successful spawn hands the parent's ends to their handles.
    public static func spawn(_ request: ProcessRequest) throws -> ChildProcess {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }

        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
        posix_spawnattr_setflags(&attributes, Int16(flags))
        posix_spawnattr_setpgroup(&attributes, 0)
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(&attributes, &emptyMask)
        var defaultSignals = sigset_t()
        sigfillset(&defaultSignals)
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)

        // Descriptors created here and not yet handed to a handle; each is closed once.
        var childEnds: [Int32] = []
        var parentEnds: [Int32] = []
        func makePipe() throws -> (read: Int32, write: Int32) {
            var fds: [Int32] = [0, 0]
            guard pipe(&fds) == 0 else { throw ChildProcessError.pipeFailed(errno: errno) }
            // Close-on-exec at once: no process another thread starts inherits them.
            for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
            return (fds[0], fds[1])
        }
        func closeAll(_ descriptors: [Int32]) {
            for fd in descriptors { close(fd) }
        }

        var inputEnd: Int32?
        var outputEnd: Int32?
        var errorEnd: Int32?

        do {
            switch request.standardInput {
            case .null:
                posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
            case .pipe:
                let fds = try makePipe()
                parentEnds.append(fds.write)
                childEnds.append(fds.read)
                _ = fcntl(fds.write, F_SETNOSIGPIPE, 1)
                posix_spawn_file_actions_adddup2(&actions, fds.read, 0)
                inputEnd = fds.write
            }
            for (target, output) in [(Int32(1), request.standardOutput), (Int32(2), request.standardError)] {
                switch output {
                case .null:
                    posix_spawn_file_actions_addopen(&actions, target, "/dev/null", O_WRONLY, 0)
                case .pipe:
                    let fds = try makePipe()
                    parentEnds.append(fds.read)
                    childEnds.append(fds.write)
                    posix_spawn_file_actions_adddup2(&actions, fds.write, target)
                    if target == 1 { outputEnd = fds.read } else { errorEnd = fds.read }
                }
            }
        } catch {
            closeAll(parentEnds + childEnds)
            throw error
        }
        if let directory = request.currentDirectory {
            posix_spawn_file_actions_addchdir(&actions, directory)
        }

        let argv = ([request.executable] + request.arguments).map { strdup($0) } + [nil]
        let envp = request.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in argv { free(pointer) }
            for pointer in envp { free(pointer) }
        }

        var pid: pid_t = 0
        let status = posix_spawn(&pid, request.executable, &actions, &attributes, argv, envp)
        closeAll(childEnds)
        guard status == 0 else {
            closeAll(parentEnds)
            throw ChildProcessError.spawnFailed(executable: request.executable, errno: status)
        }
        // From here on each parent end belongs to its handle alone.
        func handle(_ fd: Int32?) -> FileHandle? {
            fd.map { FileHandle(fileDescriptor: $0, closeOnDealloc: true) }
        }
        let process = ChildProcess(pid: pid, standardInput: handle(inputEnd), standardOutput: handle(outputEnd),
                                   standardError: handle(errorEnd))
        process.waiter.start()
        return process
    }

    /// Sends `signal` to the process only.
    public func signal(_ signal: Int32) {
        guard !hasExited else { return }
        kill(pid, signal)
    }

    /// Sends `signal` to the process group (`killpg`).
    public func signalGroup(_ signal: Int32) {
        killpg(pid, signal)
    }

    /// True once the process has been reaped.
    public var hasExited: Bool { waiter.termination != nil }

    /// The termination, once the process has exited.
    public var termination: ProcessTermination? { waiter.termination }

    /// Waits until the process exits.
    public func waitForExit() async -> ProcessTermination {
        await waiter.wait()
    }
}

/// Reaps one child with a blocking `waitpid` on a thread of its own.
private final class ExitWaiter: Sendable {
    private struct State {
        var result: ProcessTermination?
        var continuations: [CheckedContinuation<ProcessTermination, Never>] = []
    }

    private let pid: pid_t
    private let state = Mutex(State())

    init(pid: pid_t) {
        self.pid = pid
    }

    var termination: ProcessTermination? {
        state.withLock { $0.result }
    }

    func start() {
        let pid = self.pid
        let thread = Thread { [self] in
            var status: Int32 = 0
            var outcome: ProcessTermination = .exited(-1)
            while true {
                let reaped = waitpid(pid, &status, 0)
                if reaped == pid {
                    let low = status & 0x7F
                    outcome = low == 0 ? .exited((status >> 8) & 0xFF) : .signaled(low)
                    break
                }
                if reaped == -1 && errno == EINTR { continue }
                break
            }
            finish(outcome)
        }
        thread.name = "ChildProcess.wait \(pid)"
        thread.start()
    }

    private func finish(_ outcome: ProcessTermination) {
        let waiting = state.withLock { state in
            state.result = outcome
            defer { state.continuations = [] }
            return state.continuations
        }
        for continuation in waiting {
            continuation.resume(returning: outcome)
        }
    }

    func wait() async -> ProcessTermination {
        await withCheckedContinuation { continuation in
            let result = state.withLock { state in
                if state.result == nil { state.continuations.append(continuation) }
                return state.result
            }
            if let result {
                continuation.resume(returning: result)
            }
        }
    }
}

/// The outcome of a run: how the process ended, what it wrote, and whether the timeout ended it.
public struct ProcessResult: Sendable, Hashable {
    public var termination: ProcessTermination
    public var standardOutput: Data
    public var standardError: Data
    /// True when the timeout ended the process.
    public var timedOut: Bool

    public init(termination: ProcessTermination, standardOutput: Data = Data(), standardError: Data = Data(),
                timedOut: Bool = false) {
        self.termination = termination
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.timedOut = timedOut
    }

    public var standardOutputText: String { String(decoding: standardOutput, as: UTF8.self) }
    public var standardErrorText: String { String(decoding: standardError, as: UTF8.self) }

    /// True when the process exited with status 0 before the timeout.
    public var succeeded: Bool { !timedOut && termination.isSuccess }
}

/// Runs a short-lived tool and collects its output.
public enum ChildProcessRunner {
    /// Starts the request with standard output and error piped, writes `input` to standard
    /// input when given, and waits for the exit. When `timeout` passes first, the process
    /// group receives SIGTERM, then SIGKILL `killGrace` later (docs/architecture.md › Child
    /// processes). `started` receives the process once it is spawned, for a caller that signals it
    /// when the app quits.
    public static func run(_ request: ProcessRequest, input: Data? = nil, timeout: Duration? = nil,
                           killGrace: Duration = .seconds(2),
                           started: (@Sendable (ChildProcess) -> Void)? = nil) async throws -> ProcessResult {
        var request = request
        request.standardOutput = .pipe
        request.standardError = .pipe
        request.standardInput = input == nil ? .null : .pipe
        let process = try ChildProcess.spawn(request)
        started?(process)

        let output = PipeCollector(process.standardOutput!)
        let errorOutput = PipeCollector(process.standardError!)

        if let input, let handle = process.standardInput {
            Thread.detachNewThread {
                try? handle.write(contentsOf: input)
                try? handle.close()
            }
        }

        let timedOut = TimeoutFlag()
        let timer: Task<Void, Never>? = timeout.map { limit in
            Task.detached {
                try? await Task.sleep(for: limit)
                guard !Task.isCancelled, !process.hasExited else { return }
                timedOut.set()
                process.signalGroup(SIGTERM)
                try? await Task.sleep(for: killGrace)
                guard !process.hasExited else { return }
                process.signalGroup(SIGKILL)
            }
        }

        let termination = await process.waitForExit()
        timer?.cancel()
        let standardOutput = await output.collect(graceAfterExit: .milliseconds(500))
        let standardError = await errorOutput.collect(graceAfterExit: .milliseconds(500))
        return ProcessResult(termination: termination, standardOutput: standardOutput,
                             standardError: standardError, timedOut: timedOut.value)
    }
}

private final class TimeoutFlag: Sendable {
    private let flag = Atomic(false)
    func set() { flag.store(true, ordering: .relaxed) }
    var value: Bool { flag.load(ordering: .relaxed) }
}

/// Accumulates what a pipe delivers until end of file. A process that left the pipe open in
/// a grandchild does not block the caller: `collect` waits at most `graceAfterExit`.
///
/// The pipe is read with blocking reads on a thread of its own, which keeps the handle until
/// end of file: its file descriptor is never closed while a read may use it. (A
/// `readabilityHandler` can still run once after the handle was released and its descriptor
/// closed, and `availableData` then raises "Bad file descriptor".)
private final class PipeCollector: Sendable {
    private struct State {
        var data = Data()
        var finished = false
        var waiting: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    init(_ handle: FileHandle) {
        let thread = Thread { [self] in
            let descriptor = handle.fileDescriptor
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
                if count > 0 {
                    receive(Data(buffer[0..<count]))
                } else if count < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            finish()
            withExtendedLifetime(handle) {}
        }
        thread.name = "ChildProcess.read"
        thread.start()
    }

    private func receive(_ chunk: Data) {
        state.withLock { state in
            if !state.finished { state.data.append(chunk) }
        }
    }

    /// Ends the collection: at end of file, or when the grace after the exit is over.
    private func finish() {
        let continuations = state.withLock { state in
            guard !state.finished else { return [CheckedContinuation<Void, Never>]() }
            state.finished = true
            defer { state.waiting = [] }
            return state.waiting
        }
        continuations.forEach { $0.resume() }
    }

    private func waitForEnd() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let finished = state.withLock { state in
                if !state.finished { state.waiting.append(continuation) }
                return state.finished
            }
            if finished { continuation.resume() }
        }
    }

    func collect(graceAfterExit: Duration) async -> Data {
        let timer = Task.detached { [self] in
            try? await Task.sleep(for: graceAfterExit)
            guard !Task.isCancelled else { return }
            finish()
        }
        await waitForEnd()
        timer.cancel()
        return state.withLock { $0.data }
    }
}
