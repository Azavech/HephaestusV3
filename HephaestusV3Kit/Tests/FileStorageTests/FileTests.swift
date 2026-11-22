import Darwin
import Foundation
import Testing
@testable import FileStorage

@Suite("Atomic writes")
struct AtomicFileTests {
    @Test("A write creates the parent folders and the file with mode 0644, and returns its SHA-256")
    func newFile() throws {
        try withTemporaryFolder { folder in
            let url = folder.appendingPathComponent("a/b/file.yml")
            let digest = try AtomicFile.write(Data("hello\n".utf8), to: url)
            #expect(try String(contentsOf: url, encoding: .utf8) == "hello\n")
            #expect(digest == "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03")
            #expect(mode(of: url) == 0o644)
            #expect(mode(of: url.deletingLastPathComponent()) == 0o755)
            #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) == ["file.yml"])
        }
    }

    @Test("A write keeps the mode of the file it replaces; a private file gets 0600")
    func modes() throws {
        try withTemporaryFolder { folder in
            let url = folder.appendingPathComponent("file")
            try AtomicFile.write(Data("1".utf8), to: url)
            chmod(url.path, 0o640)
            try AtomicFile.write(Data("2".utf8), to: url)
            #expect(mode(of: url) == 0o640)
            let secret = folder.appendingPathComponent("token")
            try AtomicFile.write(Data("x".utf8), to: secret, newFileMode: AtomicFile.privateMode)
            #expect(mode(of: secret) == 0o600)
        }
    }

    @Test("A symbolic link is written at its target and stays a link")
    func symbolicLink() throws {
        try withTemporaryFolder { folder in
            let target = folder.appendingPathComponent("target.yml")
            try AtomicFile.write(Data("old".utf8), to: target)
            let link = folder.appendingPathComponent("link.yml")
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "target.yml")
            try AtomicFile.write(Data("new".utf8), to: link)
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "target.yml")
            #expect(try String(contentsOf: target, encoding: .utf8) == "new")
        }
    }

    @Test("A failed write leaves no temporary file and names the path")
    func failure() throws {
        try withTemporaryFolder { folder in
            let blocker = folder.appendingPathComponent("blocker")
            try Data().write(to: blocker)
            #expect(throws: StorageError.self) { try AtomicFile.write(Data("x".utf8), to: blocker.appendingPathComponent("file.yml")) }
            let readOnly = folder.appendingPathComponent("readonly", isDirectory: true)
            try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
            chmod(readOnly.path, 0o555)
            defer { chmod(readOnly.path, 0o755) }
            let error = #expect(throws: StorageError.self) { try AtomicFile.write(Data("x".utf8), to: readOnly.appendingPathComponent("f")) }
            guard case .writeFailed(let path, _)? = error else { Issue.record("unexpected \(String(describing: error))"); return }
            #expect(path.hasSuffix("readonly/f"))
            #expect(try FileManager.default.contentsOfDirectory(atPath: readOnly.path).isEmpty)
        }
    }

    @Test("Temporary files a crash left are recognized and deleted")
    func leftovers() throws {
        try withTemporaryFolder { folder in
            let leftover = ".HEPH-1.yml.\(UUID().uuidString).tmp"
            for name in [leftover, "HEPH-1.yml", ".DS_Store", ".x.tmp"] {
                try Data().write(to: folder.appendingPathComponent(name))
            }
            #expect(AtomicFile.removeLeftoverTemporaryFiles(in: folder) == [leftover])
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == [".DS_Store", ".x.tmp", "HEPH-1.yml"])
        }
    }

    @Test("The temporary name adds 42 bytes to the file name")
    func temporaryNameLength() {
        #expect(AtomicFile.temporaryNameOverhead == 42)
    }

    private func mode(of url: URL) -> mode_t {
        var status = stat()
        stat(url.path, &status)
        return status.st_mode & 0o7777
    }
}

@Suite("Own writes, the folder lock and the Trash")
struct OwnWritesLockTrashTests {
    @Test("Own writes are recognized by their SHA-256, removals by their path")
    func ownWrites() {
        let writes = OwnWrites()
        writes.recordWrite(path: "/p", sha256: AtomicFile.sha256(Data("a".utf8)))
        #expect(writes.isOwnWrite(path: "/p", data: Data("a".utf8)))
        #expect(!writes.isOwnWrite(path: "/p", data: Data("b".utf8)))
        #expect(!writes.isOwnRemoval(path: "/p"))
        writes.recordRemoval(path: "/p")
        #expect(writes.isOwnRemoval(path: "/p"))
        #expect(!writes.isOwnWrite(path: "/p", data: Data("a".utf8)))
    }

    @Test("A write through a linked folder is recognized under the path file events give, links resolved")
    func ownWritesThroughLinks() throws {
        try withTemporaryFolder { folder in
            let real = folder.appendingPathComponent("real", isDirectory: true)
            try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
            let link = folder.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
            // The temporary folder itself is under /var, which file events report as /private/var.
            let resolved = try #require(realpath(real.path, nil))
            defer { free(resolved) }
            let eventFolder = String(cString: resolved)
            #expect(eventFolder != link.path)
            let writes = OwnWrites()
            let data = Data("a".utf8)
            writes.recordWrite(path: link.appendingPathComponent("a.yml").path, sha256: AtomicFile.sha256(data))
            #expect(writes.isOwnWrite(path: eventFolder + "/a.yml", data: data))
            writes.recordRemoval(path: link.appendingPathComponent("gone.yml").path)
            #expect(writes.isOwnRemoval(path: eventFolder + "/gone.yml"))
            #expect(!writes.isOwnRemoval(path: eventFolder + "/a.yml"))
        }
    }

    @Test("The lock is exclusive until it is released")
    func lock() throws {
        try withTemporaryFolder { folder in
            let first = try FolderLock.acquire(folder)
            #expect(throws: StorageError.folderInUse(path: folder.standardizedFileURL.path)) { try FolderLock.acquire(folder) }
            first.release()
            first.release()
            let second = try FolderLock.acquire(folder)
            second.release()
            #expect(throws: StorageError.self) { try FolderLock.acquire(folder.appendingPathComponent("missing")) }
        }
    }

    @Test("A test Trash moves items into its folder, two of the same name included")
    func trash() throws {
        try withTemporaryFolder { folder in
            let trashFolder = folder.appendingPathComponent("Trash", isDirectory: true)
            let trash = Trash.folder(trashFolder)
            for _ in 0..<2 {
                let item = folder.appendingPathComponent("HEPH-1.yml")
                try Data("x".utf8).write(to: item)
                try trash.move(item)
                #expect(!FileManager.default.fileExists(atPath: item.path))
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: trashFolder.path).count == 2)
            let error = #expect(throws: StorageError.self) { try trash.move(folder.appendingPathComponent("missing")) }
            #expect(error?.path.hasSuffix("/missing") == true)
        }
    }

    @Test("A YAML file is read with the read rules and written atomically, its write recorded")
    func yamlFile() throws {
        struct Names: Codable, Equatable { var names: [String] }
        try withTemporaryFolder { folder in
            let url = folder.appendingPathComponent("names.yml")
            let missing = #expect(throws: StorageError.self) { try YAMLFile.read(Names.self, at: url) }
            guard case .readFailed? = missing else { Issue.record("unexpected \(String(describing: missing))"); return }
            #expect(YAMLFile.isMissing(url))
            let writes = OwnWrites()
            try YAMLFile.write(Names(names: ["a"]), to: url, ownWrites: writes)
            #expect(try YAMLFile.read(Names.self, at: url) == Names(names: ["a"]))
            let written = try Data(contentsOf: url)
            #expect(writes.isOwnWrite(path: AtomicFile.resolvedDestination(url).path, data: written))
            try Data("names: [a\n".utf8).write(to: url)
            let invalid = #expect(throws: StorageError.self) { try YAMLFile.read(Names.self, at: url) }
            guard case .invalidFile(let path, _)? = invalid else { Issue.record("unexpected \(String(describing: invalid))"); return }
            #expect(path == url.path)
        }
    }
}
