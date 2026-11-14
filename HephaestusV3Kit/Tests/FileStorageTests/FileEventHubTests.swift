import CoreServices
import Foundation
import Testing
@testable import FileStorage

@Suite("File events")
struct FileEventHubTests {
    private func event(_ path: String) -> FileEvent {
        FileEvent(path: path, kind: .modified)
    }

    @Test("Events close a batch after a quiet delay, in the order they came")
    func quietDelay() async throws {
        let hub = FileEventHub(quietDelay: .milliseconds(80), maximumDelay: .seconds(5))
        var batches = hub.batches.makeAsyncIterator()
        await hub.receive([event("/a")])
        await hub.receive([event("/b"), event("/c")])
        let first = try #require(await batches.next())
        #expect(first.map(\.path) == ["/a", "/b", "/c"])
        await hub.receive([event("/d")])
        let second = try #require(await batches.next())
        #expect(second.map(\.path) == ["/d"])
        await hub.stop()
    }

    @Test("A stream of events still closes a batch at the maximum delay")
    func maximumDelay() async throws {
        let hub = FileEventHub(quietDelay: .milliseconds(150), maximumDelay: .milliseconds(400))
        let start = ContinuousClock.now
        let feeder = Task {
            for index in 0..<40 {
                await hub.receive([event("/\(index)")])
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
        var batches = hub.batches.makeAsyncIterator()
        let first = try #require(await batches.next())
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .milliseconds(900))
        #expect(first.count < 40)
        #expect(first.first?.path == "/0")
        feeder.cancel()
        await hub.stop()
    }

    @Test("A real FSEvents stream reports a file written in a watched folder")
    func realStream() async throws {
        try await withTemporaryFolder { folder in
            let hub = FileEventHub(quietDelay: .milliseconds(100), maximumDelay: .seconds(1))
            #expect(await hub.watch(folder.path))
            #expect(await hub.watchedFolders == [folder.path])
            try await Task.sleep(for: .milliseconds(200))
            try Data("x".utf8).write(to: folder.appendingPathComponent("file.yml"))
            let found = await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    for await batch in hub.batches where batch.contains(where: { $0.path.hasSuffix("/file.yml") && $0.changesMoreThanMetadata }) {
                        return true
                    }
                    return false
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(10))
                    return false
                }
                let first = await group.next() ?? false
                group.cancelAll()
                await hub.stop()
                return first
            }
            #expect(found)
        }
    }

    @Test("FSEvents flags become kinds")
    func kinds() {
        #expect(FileWatcher.kind(of: UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)) == .created)
        #expect(FileWatcher.kind(of: UInt32(kFSEventStreamEventFlagMustScanSubDirs)) == .mustRescan)
        #expect(FileWatcher.kind(of: UInt32(kFSEventStreamEventFlagItemXattrMod)) == .metadata)
        #expect(!FileEvent(path: "/a", kind: .metadata).changesMoreThanMetadata)
        #expect(FileEvent(path: "/a", kind: .rootChanged).changesMoreThanMetadata)
    }
}
