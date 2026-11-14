import CoreServices
import Foundation
import Synchronization

/// One change FSEvents reported: the path, with symbolic links resolved (`/private/var/…` for
/// `/var/…`), and what happened to it.
public struct FileEvent: Sendable, Hashable {
    public struct Kind: OptionSet, Sendable, Hashable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        public static let created = Kind(rawValue: 1 << 0)
        public static let removed = Kind(rawValue: 1 << 1)
        public static let renamed = Kind(rawValue: 1 << 2)
        public static let modified = Kind(rawValue: 1 << 3)
        /// Only the item's dates, permissions or extended attributes changed.
        public static let metadata = Kind(rawValue: 1 << 4)
        /// Events were coalesced or dropped: anything below the path may have changed.
        public static let mustRescan = Kind(rawValue: 1 << 5)
        /// The watched folder itself, or one of its parents, was created, removed or moved.
        public static let rootChanged = Kind(rawValue: 1 << 6)
    }

    public var path: String
    public var kind: Kind

    public init(path: String, kind: Kind) {
        self.path = path
        self.kind = kind
    }

    /// The item was created, removed, renamed or its content changed, or anything below it may have:
    /// more than its metadata.
    public var changesMoreThanMetadata: Bool {
        !kind.isDisjoint(with: [.created, .removed, .renamed, .modified, .mustRescan, .rootChanged])
    }
}

/// One FSEvents stream on one folder, with file-level events, delivered in order to `handler` on a
/// private queue. The folder may not exist yet: FSEvents then reports only `rootChanged`, and the
/// owner restarts the stream once the folder appears (`restart()`).
final class FileWatcher: Sendable {
    /// The watched folder, as the owner named it.
    let path: String
    /// Latency of the stream; `FileEventHub` batches the events.
    static let latency: CFTimeInterval = 0.05

    private let queue: DispatchQueue
    private let handler: @Sendable ([FileEvent]) -> Void
    // `FSEventStreamRef` is an opaque pointer, only touched under the lock or on `queue`.
    private let stream = Mutex<UnsafeStream?>(nil)

    private struct UnsafeStream: @unchecked Sendable {
        let ref: FSEventStreamRef
    }

    init(path: String, handler: @escaping @Sendable ([FileEvent]) -> Void) {
        self.path = path
        self.handler = handler
        queue = DispatchQueue(label: "FileStorage.FileWatcher")
    }

    deinit {
        stop()
    }

    /// Starts the stream. Returns false when FSEvents refuses it.
    @discardableResult
    func start() -> Bool {
        stream.withLock { stream in
            guard stream == nil else { return true }
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                               retain: nil, release: nil, copyDescription: nil)
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagUseCFTypes)
            guard let created = FSEventStreamCreate(nil, FileWatcher.callback, &context, [path] as CFArray,
                                                    FSEventStreamEventId(kFSEventStreamEventIdSinceNow), Self.latency, flags)
            else { return false }
            FSEventStreamSetDispatchQueue(created, queue)
            guard FSEventStreamStart(created) else {
                FSEventStreamInvalidate(created)
                FSEventStreamRelease(created)
                return false
            }
            stream = UnsafeStream(ref: created)
            return true
        }
    }

    /// Stops the stream; no event is delivered after this returns. Never call it from the handler.
    func stop() {
        guard let current = stream.withLock({ stream in
            defer { stream = nil }
            return stream
        }) else { return }
        // Invalidating on the stream's own queue waits for a callback in progress to end.
        queue.sync {
            FSEventStreamStop(current.ref)
            FSEventStreamInvalidate(current.ref)
            FSEventStreamRelease(current.ref)
        }
    }

    /// Stops and starts the stream again, so that FSEvents watches the folder where it is now (after it
    /// was created, removed or moved).
    @discardableResult
    func restart() -> Bool {
        stop()
        return start()
    }

    /// The kinds of an FSEvents flag set.
    static func kind(of flags: FSEventStreamEventFlags) -> FileEvent.Kind {
        func has(_ flag: Int) -> Bool { flags & FSEventStreamEventFlags(flag) != 0 }
        var kind: FileEvent.Kind = []
        if has(kFSEventStreamEventFlagItemCreated) { kind.insert(.created) }
        if has(kFSEventStreamEventFlagItemRemoved) { kind.insert(.removed) }
        if has(kFSEventStreamEventFlagItemRenamed) { kind.insert(.renamed) }
        if has(kFSEventStreamEventFlagItemModified) || has(kFSEventStreamEventFlagItemCloned) { kind.insert(.modified) }
        if has(kFSEventStreamEventFlagItemInodeMetaMod) || has(kFSEventStreamEventFlagItemFinderInfoMod)
            || has(kFSEventStreamEventFlagItemChangeOwner) || has(kFSEventStreamEventFlagItemXattrMod) {
            kind.insert(.metadata)
        }
        if has(kFSEventStreamEventFlagMustScanSubDirs) || has(kFSEventStreamEventFlagUserDropped)
            || has(kFSEventStreamEventFlagKernelDropped) || has(kFSEventStreamEventFlagMount)
            || has(kFSEventStreamEventFlagUnmount) {
            kind.insert(.mustRescan)
        }
        if has(kFSEventStreamEventFlagRootChanged) { kind.insert(.rootChanged) }
        return kind
    }

    /// True for bookkeeping events, which change no item.
    static func isBookkeeping(_ flags: FSEventStreamEventFlags) -> Bool {
        flags & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone | kFSEventStreamEventFlagEventIdsWrapped) != 0
    }

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info else { return }
        let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
        let array = unsafeBitCast(paths, to: NSArray.self)
        var events: [FileEvent] = []
        events.reserveCapacity(count)
        for index in 0..<count {
            guard let path = array[index] as? String, !isBookkeeping(flags[index]) else { continue }
            events.append(FileEvent(path: path, kind: kind(of: flags[index])))
        }
        if !events.isEmpty {
            watcher.handler(events)
        }
    }
}
