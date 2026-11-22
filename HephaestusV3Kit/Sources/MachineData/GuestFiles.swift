import ExternalTools
import Foundation
import MCPKit

/// Shell words for a guest's `/bin/zsh -lc`.
public enum GuestShell {
    /// One single-quoted word.
    public static func quote(_ text: String) -> String {
        "'" + text.replacing("'", with: "'\\''") + "'"
    }

    /// A guest path as a shell word: `~/x` becomes `"$HOME"/'x'`.
    public static func path(_ path: String) -> String {
        if path == "~" { return "\"$HOME\"" }
        if path.hasPrefix("~/") { return "\"$HOME\"/" + quote(String(path.dropFirst(2))) }
        return quote(path)
    }

    /// An absolute guest path, or one starting with `~/`.
    public static func isGuestPath(_ path: String) -> Bool {
        path.hasPrefix("/") || path == "~" || path.hasPrefix("~/")
    }
}

extension MachineHost {
    /// The agent's `readFile` and `writeFile` move 8 MiB at a time.
    public static let chunkSize = 8_388_608

    /// Copies a file or folder of this Mac into the guest: a file 8 MiB at a time with its permission bits, a
    /// folder's contents through a tar archive.
    public func copyIn(_ id: String, from source: URL, to destination: String) async throws(MachineError) {
        guard GuestShell.isGuestPath(destination) else { throw MachineError(.invalid, "to: use an absolute path or a path starting with ~/.") }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isFolder) else {
            throw MachineError(.notFound, "\(source.path) does not exist on this Mac.")
        }
        if !isFolder.boolValue {
            try await copyFileIn(id, source, to: destination)
            return
        }
        let archive = try Self.archiveFile()
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
        try await Self.tar(["-c", "-f", archive.path, "-C", source.path, "."])
        let guestArchive = "/tmp/hephaestus-copy-\(UUID().uuidString).tar"
        try await copyFileIn(id, archive, to: guestArchive)
        let folder = GuestShell.path(destination)
        let result = try await shell(id, command: "/bin/mkdir -p \(folder) && /usr/bin/tar -x -p -f \(GuestShell.quote(guestArchive)) -C \(folder); "
            + "status=$?; /bin/rm -f \(GuestShell.quote(guestArchive)); exit $status", timeout: 1800)
        try Self.requireSuccess(result)
    }

    /// Copies a file or folder of the guest to this Mac: a file through a partial file beside the destination,
    /// a folder's contents through a tar archive.
    public func copyOut(_ id: String, from source: String, to destination: URL) async throws(MachineError) {
        guard GuestShell.isGuestPath(source) else { throw MachineError(.invalid, "from: use an absolute path or a path starting with ~/.") }
        let stat = try await agentRequest(id, method: "stat", params: ["path": .string(source)]).result
        guard stat["exists"]?.boolValue == true else { throw MachineError(.notFound, "\(source) does not exist in the guest.") }
        guard stat["isDirectory"]?.boolValue == true else {
            try Self.requireFileDestination(destination)
            try await copyFileOut(id, source, to: destination, mode: stat["mode"]?.intValue)
            return
        }
        let guestArchive = "/tmp/hephaestus-copy-\(UUID().uuidString).tar"
        let quoted = GuestShell.quote(guestArchive)
        try Self.requireSuccess(try await shell(id, command: "/usr/bin/tar -c -f \(quoted) -C \(GuestShell.path(source)) .; status=$?; "
            + "[ $status -eq 0 ] || /bin/rm -f \(quoted); exit $status", timeout: 1800))
        let archive = try Self.archiveFile()
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
        do {
            try await copyFileOut(id, guestArchive, to: archive, mode: nil)
        } catch {
            _ = try? await shell(id, command: "/bin/rm -f \(quoted)")
            throw error
        }
        _ = try? await shell(id, command: "/bin/rm -f \(quoted)")
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            throw Self.cannotWrite(destination, error)
        }
        try await Self.tar(["-x", "-p", "-f", archive.path, "-C", destination.path])
    }

    private func copyFileIn(_ id: String, _ source: URL, to destination: String) async throws(MachineError) {
        let handle: FileHandle
        let mode: Int?
        do {
            handle = try FileHandle(forReadingFrom: source)
            mode = (try FileManager.default.attributesOfItem(atPath: source.path)[.posixPermissions] as? NSNumber)?.intValue
        } catch {
            throw MachineError(.internal, "\(source.path) cannot be read: \(MachineFailure.message(of: error))")
        }
        defer { try? handle.close() }
        var offset = 0
        while true {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: Self.chunkSize) ?? Data()
            } catch {
                throw MachineError(.internal, "\(source.path) cannot be read: \(MachineFailure.message(of: error))")
            }
            // The mode comes with the last write: a read-only mode set with the first would refuse the next chunks.
            if chunk.isEmpty, offset > 0 {
                if let mode {
                    _ = try await agentRequest(id, method: "writeFile",
                                               params: ["path": .string(destination), "offset": .int(offset), "mode": .int(mode & 0o7777)], data: Data())
                }
                break
            }
            let last = chunk.count < Self.chunkSize
            var params: [String: JSONValue] = ["path": .string(destination), "offset": .int(offset)]
            if offset == 0 { params["truncate"] = true }
            if last, let mode { params["mode"] = .int(mode & 0o7777) }
            _ = try await agentRequest(id, method: "writeFile", params: params, data: chunk)
            offset += chunk.count
            if last { break }
        }
    }

    private func copyFileOut(_ id: String, _ source: String, to destination: URL, mode: Int?) async throws(MachineError) {
        let manager = FileManager.default
        let partial = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString)")
        do {
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: partial)
        } catch {
            throw Self.cannotWrite(destination, error)
        }
        var completed = false
        defer { if !completed { try? manager.removeItem(at: partial) } }
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: partial)
        } catch {
            throw Self.cannotWrite(destination, error)
        }
        defer { try? handle.close() }
        var offset = 0
        while true {
            let response = try await agentRequest(id, method: "readFile",
                                                  params: ["path": .string(source), "offset": .int(offset), "length": .int(Self.chunkSize)])
            do {
                try handle.write(contentsOf: response.data)
            } catch {
                throw Self.cannotWrite(destination, error)
            }
            offset += response.data.count
            if response.result["eof"]?.boolValue != false || response.data.isEmpty { break }
        }
        // Again just before the swap: a folder made there while the file came is refused too.
        try Self.requireFileDestination(destination)
        do {
            try handle.close()
            if let mode { try manager.setAttributes([.posixPermissions: mode & 0o7777], ofItemAtPath: partial.path) }
            if manager.fileExists(atPath: destination.path) {
                _ = try manager.replaceItemAt(destination, withItemAt: partial)
            } else {
                try manager.moveItem(at: partial, to: destination)
            }
            completed = true
        } catch {
            throw Self.cannotWrite(destination, error)
        }
    }

    private static func archiveFile() throws(MachineError) -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hephaestus-copy-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw cannotWrite(folder, error)
        }
        return folder.appendingPathComponent("copy.tar")
    }

    /// `/usr/bin/tar` on this Mac, at most 30 minutes.
    /// `/usr/bin/tar` on this Mac through the app's process runner, which reads its output while it runs (a full
    /// error pipe can't stall it), ends it after 30 minutes, and ends it with the app.
    private static func tar(_ arguments: [String]) async throws(MachineError) {
        let request = ProcessRequest(executable: "/usr/bin/tar", arguments: arguments, environment: ProcessInfo.processInfo.environment,
                                     standardOutput: .null)
        let result: ProcessResult
        do {
            result = try await SystemProcessRunner.shared.run(request, timeout: tarTimeout)
        } catch {
            throw MachineError(.internal, "tar could not run: \(MachineFailure.message(of: error))")
        }
        guard !result.timedOut else { throw MachineError(.internal, "tar didn't finish within 30 minutes.") }
        guard result.termination.isSuccess else {
            let message = String(decoding: result.standardError, as: UTF8.self)
            throw MachineError(.internal, "tar failed: \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    static let tarTimeout: Duration = .seconds(1800)

    private static func requireSuccess(_ result: ShellResult) throws(MachineError) {
        guard result.exitStatus != 0 else { return }
        let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        throw MachineError(.internal, result.timedOut ? "tar in the guest timed out." : "tar in the guest failed: \(message)")
    }

    /// A guest file goes to a file of this Mac: a folder at its destination is refused, never replaced by it.
    nonisolated static func requireFileDestination(_ destination: URL) throws(MachineError) {
        var isFolder: ObjCBool = false
        if FileManager.default.fileExists(atPath: destination.path, isDirectory: &isFolder), isFolder.boolValue {
            throw MachineError(.invalid, "to: \(destination.path) is a folder on this Mac: give the path of the file to write.")
        }
    }

    private static func cannotWrite(_ url: URL, _ error: any Error) -> MachineError {
        MachineError(.internal, "\(url.path) cannot be written: \(MachineFailure.message(of: error))")
    }
}
