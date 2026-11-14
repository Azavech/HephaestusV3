import Foundation

/// Where removed files go: the files the app removes are moved to the Trash, never deleted
/// (docs/data.md › Atomic writes). Tests use `folder(_:)`, so they never fill the Trash of the user
/// running them.
public struct Trash: Sendable {
    private let moveItem: @Sendable (URL) throws -> Void

    public init(move: @escaping @Sendable (URL) throws -> Void) {
        moveItem = move
    }

    /// Moves the item at `url` to the Trash. Throws `StorageError.trashFailed`.
    public func move(_ url: URL) throws {
        do {
            try moveItem(url)
        } catch let error as StorageError {
            throw error
        } catch {
            var reason = error.localizedDescription
            while reason.hasSuffix(".") { reason.removeLast() }
            throw StorageError.trashFailed(path: url.path, reason: reason)
        }
    }

    /// The Trash of this Mac (`FileManager.trashItem`).
    public static let system = Trash { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// A folder that stands for the Trash: each item moves into it under a new UUID folder, which keeps
    /// two items of the same name apart.
    public static func folder(_ folder: URL) -> Trash {
        Trash { url in
            let destination = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: destination.appendingPathComponent(url.lastPathComponent))
        }
    }
}
