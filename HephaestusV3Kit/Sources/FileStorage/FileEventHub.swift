import Foundation

/// Watches folders with FSEvents and hands their events out in batches (docs/data.md › Outside
/// changes): a batch ends 300 ms after its last event, or 2 s after its first one, whichever comes
/// first, so a git checkout that touches a thousand files is processed once, and a stream of changes
/// still shows within 2 s.
public actor FileEventHub {
    /// A batch ends after this long without a new event.
    public static let quietDelay: Duration = .milliseconds(300)
    /// A batch ends at the latest this long after its first event.
    public static let maximumDelay: Duration = .seconds(2)

    /// The batches, in order; each holds the events in the order they arrived.
    public nonisolated let batches: AsyncStream<[FileEvent]>

    private let output: AsyncStream<[FileEvent]>.Continuation
    private let inputStream: AsyncStream<[FileEvent]>
    private let input: AsyncStream<[FileEvent]>.Continuation
    private let quietDelay: Duration
    private let maximumDelay: Duration
    private var watchers: [String: FileWatcher] = [:]
    private var consumer: Task<Void, Never>?
    private var pending: [FileEvent] = []
    private var firstArrival: ContinuousClock.Instant?
    private var timer: Task<Void, Never>?
    private var generation = 0

    /// Tests pass shorter delays.
    public init(quietDelay: Duration = FileEventHub.quietDelay, maximumDelay: Duration = FileEventHub.maximumDelay) {
        self.quietDelay = quietDelay
        self.maximumDelay = maximumDelay
        (batches, output) = AsyncStream.makeStream(of: [FileEvent].self)
        (inputStream, input) = AsyncStream.makeStream(of: [FileEvent].self)
    }

    /// The folders watched, in path order.
    public var watchedFolders: [String] { watchers.keys.sorted() }

    /// Starts watching a folder and everything in it; watching it again does nothing. Returns false
    /// when FSEvents refuses the stream.
    @discardableResult
    public func watch(_ folder: String) -> Bool {
        guard watchers[folder] == nil else { return true }
        startConsuming()
        let input = input
        let watcher = FileWatcher(path: folder) { events in input.yield(events) }
        guard watcher.start() else { return false }
        watchers[folder] = watcher
        return true
    }

    /// Stops watching a folder.
    public func unwatch(_ folder: String) {
        watchers.removeValue(forKey: folder)?.stop()
    }

    /// Restarts the stream of a folder that was created, removed or moved, so that FSEvents follows it
    /// where it is now.
    public func restart(_ folder: String) {
        watchers[folder]?.restart()
    }

    /// Stops every stream and ends `batches`; the pending events are dropped.
    public func stop() {
        for watcher in watchers.values { watcher.stop() }
        watchers.removeAll()
        consumer?.cancel()
        timer?.cancel()
        pending.removeAll()
        input.finish()
        output.finish()
    }

    /// Adds events to the pending batch and schedules its end. The streams call it in order; tests
    /// call it with events they make up.
    public func receive(_ events: [FileEvent]) {
        guard !events.isEmpty else { return }
        let now = ContinuousClock.now
        pending.append(contentsOf: events)
        if firstArrival == nil {
            firstArrival = now
        }
        var delay = quietDelay
        if let firstArrival {
            delay = min(delay, max(firstArrival + maximumDelay - now, .zero))
        }
        timer?.cancel()
        generation += 1
        let generation = generation
        timer = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.closeBatch(generation: generation)
        }
    }

    private func closeBatch(generation: Int) {
        guard generation == self.generation, !pending.isEmpty else { return }
        output.yield(pending)
        pending.removeAll()
        firstArrival = nil
        timer = nil
    }

    private func startConsuming() {
        guard consumer == nil else { return }
        let stream = inputStream
        consumer = Task { [weak self] in
            for await events in stream {
                await self?.receive(events)
            }
        }
    }
}
