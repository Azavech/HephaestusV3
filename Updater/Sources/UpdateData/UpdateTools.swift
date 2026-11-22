import Foundation

/// Runs a tool with standard input, output and error on `/dev/null` and returns its exit status; -1 when it can't
/// start.
public enum ProcessRunner {
    public static func run(_ executable: String, _ arguments: [String]) async -> Int32 {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { process in
                continuation.resume(returning: process.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                // A process that didn't start never calls its termination handler.
                continuation.resume(returning: -1)
            }
        }
    }
}

/// The tools the Updater runs, injectable for tests: tests never touch LaunchServices, and fake the disk image.
public struct UpdateTools: Sendable {
    /// Runs a tool and returns its exit status (`codesign`, `open`).
    public var run: @Sendable (_ executable: String, _ arguments: [String]) async -> Int32
    /// Copies `HephaestusV3.app` out of a disk image into a folder; false when the image can't be read.
    public var unpack: @Sendable (_ diskImage: URL, _ destination: URL) async -> Bool
    /// Forgets a copy of the app in LaunchServices (`lsregister -u`), before it is moved or deleted, so that only
    /// `/Applications/HephaestusV3.app` stays registered (docs/updater.md › LaunchServices).
    public var unregister: @Sendable (_ app: URL) async -> Void

    public init(run: @escaping @Sendable (String, [String]) async -> Int32,
                unpack: @escaping @Sendable (URL, URL) async -> Bool,
                unregister: @escaping @Sendable (URL) async -> Void) {
        self.run = run
        self.unpack = unpack
        self.unregister = unregister
    }

    public static let system = UpdateTools(
        run: { await ProcessRunner.run($0, $1) },
        unpack: { await DiskImage.copyApp(from: $0, to: $1, run: { await ProcessRunner.run($0, $1) }) },
        // A path no longer there is forgotten too: LaunchServices keeps the record of a copy moved or deleted.
        unregister: { app in
            _ = await ProcessRunner.run(LaunchServices.lsregister, ["-u", app.path])
        }
    )
}

public enum LaunchServices {
    public static let lsregister =
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
}

/// A release's disk image, read with `hdiutil` (docs/updater.md › Download and verification, step 5).
public enum DiskImage {
    public static let appName = "HephaestusV3.app"

    /// Mounts `diskImage` read-only and hidden at `<destination's folder>/mount`, copies its `HephaestusV3.app` to
    /// `destination/HephaestusV3.app` with `ditto`, forgets the mounted copy in LaunchServices, and detaches the
    /// image. True when the image mounted and the copy, if there was an app to copy, succeeded.
    public static func copyApp(from diskImage: URL, to destination: URL,
                               run: @Sendable (String, [String]) async -> Int32) async -> Bool {
        let manager = FileManager.default
        let mount = destination.deletingLastPathComponent().appendingPathComponent("mount", isDirectory: true)
        // A mount left by an Updater that ended in the middle.
        if manager.fileExists(atPath: mount.path) {
            _ = await run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
            try? manager.removeItem(at: mount)
        }
        do {
            try manager.createDirectory(at: mount, withIntermediateDirectories: true)
            try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            return false
        }
        guard await run("/usr/bin/hdiutil", ["attach", diskImage.path, "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount.path]) == 0
        else {
            try? manager.removeItem(at: mount)
            return false
        }
        let source = mount.appendingPathComponent(appName, isDirectory: true)
        var copied = true
        if manager.fileExists(atPath: source.path) {
            copied = await run("/usr/bin/ditto", [source.path, destination.appendingPathComponent(appName).path]) == 0
            _ = await run(LaunchServices.lsregister, ["-u", source.path])
        }
        if await run("/usr/bin/hdiutil", ["detach", mount.path]) != 0 {
            _ = await run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
        }
        try? manager.removeItem(at: mount)
        return copied
    }
}
