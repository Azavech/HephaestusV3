import Foundation
import Synchronization

/// The app's log, `<data folder>/Logs/engine.log` as V2's: the MCP server's life and its tool calls, and the
/// background Claude calls that failed. One line each, `<UTC time with ms> <LEVEL> <part>: <message>`; never a token,
/// a call's arguments or its result (docs/data.md › App log). Emptied at launch once over 10 MB.
public final class AppLog: Sendable {
    public enum Level: String, Sendable {
        case info = "INFO"
        case warning = "WARNING"
        case error = "ERROR"
    }

    /// The log is emptied at launch once larger than this.
    public static let maximumSize = 10 * 1024 * 1024

    private let handle: Mutex<FileHandle?>

    /// A log at `url`; nil writes nothing, as in tests and without a data folder.
    public init(url: URL?) {
        handle = Mutex(url.flatMap(Self.open))
    }

    public func write(_ level: Level, _ part: String, _ message: String) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let line = "\(formatter.string(from: Date())) \(level.rawValue) \(part): \(message)\n"
        handle.withLock { try? $0?.write(contentsOf: Data(line.utf8)) }
    }

    private static func open(_ url: URL) -> FileHandle? {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if size > maximumSize || !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        _ = try? handle.seekToEnd()
        return handle
    }
}
