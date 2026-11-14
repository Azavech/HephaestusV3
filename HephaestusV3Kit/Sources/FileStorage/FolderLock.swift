import Darwin
import Foundation
import Synchronization

/// The exclusive, non-blocking `flock(2)` lock a process holds on a folder until it releases it or
/// exits; the system releases it when the process ends, after a crash too. The app holds one on its
/// data folder, so two copies of it never write the same files (docs/data.md › Data folder).
public final class FolderLock: Sendable {
    public let path: String
    private let descriptor: Mutex<Int32>

    private init(path: String, descriptor: Int32) {
        self.path = path
        self.descriptor = Mutex(descriptor)
    }

    deinit {
        release()
    }

    /// Opens the folder and takes its lock. Throws `StorageError.folderInUse` when another process
    /// holds it, `folderUnavailable` when the folder can't be opened.
    public static func acquire(_ folder: URL) throws -> FolderLock {
        let path = folder.standardizedFileURL.path
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw StorageError.folderUnavailable(path: path, reason: String(cString: strerror(errno)))
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK {
                throw StorageError.folderInUse(path: path)
            }
            throw StorageError.folderUnavailable(path: path, reason: String(cString: strerror(code)))
        }
        return FolderLock(path: path, descriptor: descriptor)
    }

    /// Releases the lock; later calls do nothing.
    public func release() {
        descriptor.withLock { descriptor in
            guard descriptor >= 0 else { return }
            flock(descriptor, LOCK_UN)
            close(descriptor)
            descriptor = -1
        }
    }
}
