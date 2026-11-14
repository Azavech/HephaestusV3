import Foundation
import Synchronization
@testable import ExternalTools

/// Answers runs from a script, without starting any process, and keeps the requests it got.
final class FakeRunner: ProcessRunning {
    private let answer: @Sendable (ProcessRequest, Data?) throws -> ProcessResult
    private let received = Mutex<[ProcessRequest]>([])

    init(_ answer: @escaping @Sendable (ProcessRequest, Data?) throws -> ProcessResult) {
        self.answer = answer
    }

    /// A runner whose every run exits with `status` after printing `output`.
    convenience init(status: Int32 = 0, output: String = "", error: String = "", timedOut: Bool = false) {
        self.init { _, _ in
            ProcessResult(termination: .exited(status), standardOutput: Data(output.utf8), standardError: Data(error.utf8),
                          timedOut: timedOut)
        }
    }

    var requests: [ProcessRequest] { received.withLock { $0 } }

    func run(_ request: ProcessRequest, input: Data?, timeout: Duration?) async throws -> ProcessResult {
        received.withLock { $0.append(request) }
        return try answer(request, input)
    }
}

/// Runs `body` with a new empty folder in the system's temporary folder, deleted afterwards.
func withTemporaryFolder<T>(_ body: (URL) throws -> T) throws -> T {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ExternalToolsTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    return try body(folder)
}
