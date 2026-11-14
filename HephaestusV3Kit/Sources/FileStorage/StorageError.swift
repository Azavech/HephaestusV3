import Foundation
import Yams

/// What went wrong with a file or a folder. Messages name the path and never quote a file's content;
/// they are technical details, shown under a localized sentence of the window that hit them.
public enum StorageError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The file breaks a read rule (docs/data.md › Read rules).
    case invalidFile(path: String, reason: String)
    /// The file can't be read: it is missing, or the system refused it.
    case readFailed(path: String, reason: String)
    /// A step of an atomic write failed (docs/data.md › Atomic writes).
    case writeFailed(path: String, reason: String)
    /// Another process holds the folder's lock.
    case folderInUse(path: String)
    /// The folder can't be created or opened.
    case folderUnavailable(path: String, reason: String)
    /// An item can't be moved to the Trash.
    case trashFailed(path: String, reason: String)

    public var description: String {
        switch self {
        case let .invalidFile(path, reason): "\(path) is invalid: \(reason)"
        case let .readFailed(path, reason): "\(path) cannot be read: \(reason)"
        case let .writeFailed(path, reason): "\(path) cannot be written: \(reason)"
        case let .folderInUse(path): "\(path) is in use by another process"
        case let .folderUnavailable(path, reason): "\(path) cannot be used: \(reason)"
        case let .trashFailed(path, reason): "\(path) cannot be moved to the Trash: \(reason)"
        }
    }

    /// The path the error names.
    public var path: String {
        switch self {
        case let .invalidFile(path, _), let .readFailed(path, _), let .writeFailed(path, _), let .folderInUse(path),
             let .folderUnavailable(path, _), let .trashFailed(path, _):
            path
        }
    }

    /// The reason, without the path.
    public var reason: String {
        switch self {
        case let .invalidFile(_, reason), let .readFailed(_, reason), let .writeFailed(_, reason),
             let .folderUnavailable(_, reason), let .trashFailed(_, reason):
            reason
        case .folderInUse:
            "in use by another process"
        }
    }
}

/// A file's content that breaks the format, before the path is known.
public struct FileFormatError: Error, Equatable, Sendable, CustomStringConvertible {
    public var reason: String

    public init(_ reason: String) {
        self.reason = reason
    }

    public var description: String { reason }

    /// A short reason for any decoding error, without the content.
    public static func describe(_ error: any Error) -> String {
        switch error {
        case let error as FileFormatError:
            error.reason
        case let error as DecodingError:
            describe(decoding: error)
        case let error as YamlError:
            "not valid YAML: " + (String(describing: error).split(separator: "\n").first.map(String.init) ?? "")
        default:
            String(describing: error)
        }
    }

    private static func describe(decoding error: DecodingError) -> String {
        func path(_ codingPath: [any CodingKey]) -> String {
            let text = codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
            return text.isEmpty ? "the root" : text
        }
        switch error {
        case let .keyNotFound(key, context):
            return "\(path(context.codingPath + [key])): the required key is missing or null"
        case let .valueNotFound(_, context):
            return "\(path(context.codingPath)): the value is missing"
        case let .typeMismatch(type, context):
            return "\(path(context.codingPath)): expected a value of type \(type)"
        case let .dataCorrupted(context):
            if let underlying = context.underlyingError {
                return "\(path(context.codingPath)): \(describe(underlying))"
            }
            return "\(path(context.codingPath)): \(context.debugDescription)"
        @unknown default:
            return String(describing: error)
        }
    }
}
