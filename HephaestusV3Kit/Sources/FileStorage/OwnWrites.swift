import Foundation
import Synchronization

/// The writes and removals the app made itself, by path, so that the file events they cause are
/// recognized and ignored (docs/data.md › Outside changes).
public final class OwnWrites: Sendable {
    private struct State {
        var digests: [String: String] = [:]
        var removals: Set<String> = []
    }

    private let state = Mutex(State())

    public init() {}

    /// Records the SHA-256 of the bytes written at `path`.
    public func recordWrite(path: String, sha256: String) {
        let path = Self.key(path)
        state.withLock {
            $0.digests[path] = sha256
            $0.removals.remove(path)
        }
    }

    /// Records that the file at `path` was moved to the Trash.
    public func recordRemoval(path: String) {
        let path = Self.key(path)
        state.withLock {
            $0.digests[path] = nil
            $0.removals.insert(path)
        }
    }

    /// True when `data` is what the app last wrote at `path`.
    public func isOwnWrite(path: String, data: Data) -> Bool {
        let path = Self.key(path)
        let digest = state.withLock { $0.digests[path] }
        return digest == AtomicFile.sha256(data)
    }

    /// True when the app itself removed the file at `path`.
    public func isOwnRemoval(path: String) -> Bool {
        let path = Self.key(path)
        return state.withLock { $0.removals.contains(path) }
    }

    /// `path` with its folder's symbolic links resolved, as file events give it (`/private/tmp/…` for `/tmp/…`,
    /// a linked folder's target): a write recorded under one spelling is recognized under the other. The file
    /// itself may be gone, as after a removal; a folder that can't be resolved leaves the path as given.
    static func key(_ path: String) -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard let resolved = realpath(url.deletingLastPathComponent().path, nil) else { return url.path }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            .appendingPathComponent(url.lastPathComponent).path
    }
}
