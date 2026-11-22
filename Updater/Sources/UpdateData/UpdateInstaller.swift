import Darwin
import Foundation

/// The result of an install.
public enum InstallOutcome: Sendable, Equatable {
    /// The app was replaced; the Updater ends with status 0.
    case installed
    /// Replacing the app failed with this text, written to `install-failed`; the Updater ends with status 1.
    case failed(String)
}

/// Steps 5 to 8 of docs/updater.md › Restart for an update, and the `install-failed` file of › Install failure.
public struct UpdateInstaller: Sendable {
    /// `~/Library/Caches/HephaestusV3/Updates/`.
    public var cacheRoot: URL
    /// The Updater's environment: its `HEPHAESTUS_*` variables go to the relaunched app.
    public var environment: [String: String]
    public var tools: UpdateTools
    /// Logs a failure of steps 6 to 8, which doesn't change the outcome.
    public var log: @Sendable (String) -> Void

    public static let installFailedName = "install-failed"
    public static let quarantineAttribute = "com.apple.quarantine"

    public init(cacheRoot: URL, environment: [String: String] = ProcessInfo.processInfo.environment, tools: UpdateTools = .system,
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.cacheRoot = cacheRoot
        self.environment = environment
        self.tools = tools
        self.log = log
    }

    /// Replaces `app` with the verified `update` of `build`: the previous version goes with the swap, and no copy
    /// of it stays. With `relaunch` (a restart) the app opens again, by its path: the new one, or the unchanged one
    /// after a failure.
    public func install(update: URL, build: Int, replacing app: URL, relaunch: Bool, activate: Bool) async -> InstallOutcome {
        let folder = UpdateDownloader.buildFolder(build, in: cacheRoot)

        // Step 5: the cached copy is forgotten in LaunchServices, then takes the app's place.
        await tools.unregister(update)
        do {
            _ = try FileManager.default.replaceItemAt(app, withItemAt: update)
        } catch {
            let text = (error as NSError).localizedDescription
            writeInstallFailed(text, in: folder)
            if relaunch {
                await relaunchApp(app, activate: activate)
            }
            return .failed(text)
        }

        // Step 6: no quarantine attribute on the installed app.
        removeQuarantine(from: app)

        // Step 7: the relaunch, for a restart.
        if relaunch {
            await relaunchApp(app, activate: activate)
        }

        // Step 8: the build's cache folder, then its copy's path forgotten again: LaunchServices can register the
        // copy between step 5's forgetting and the swap, and keeps that record once the copy has moved.
        do {
            try FileManager.default.removeItem(at: folder)
        } catch {
            log("Deleting \(folder.path) failed: \(error.localizedDescription)")
        }
        await tools.unregister(update)
        return .installed
    }

    /// `/usr/bin/open`'s arguments: `-g` when `activate` is false, one `--env NAME=value` per `HEPHAESTUS_*`
    /// variable, by name, then the app's path: never its bundle id, which could open another copy.
    public func relaunchArguments(app: URL, activate: Bool) -> [String] {
        var arguments: [String] = activate ? [] : ["-g"]
        for name in environment.keys.sorted() where name.hasPrefix("HEPHAESTUS_") {
            arguments += ["--env", "\(name)=\(environment[name] ?? "")"]
        }
        arguments.append(app.path)
        return arguments
    }

    func relaunchApp(_ app: URL, activate: Bool) async {
        let status = await tools.run("/usr/bin/open", relaunchArguments(app: app, activate: activate))
        if status != 0 {
            log("Opening \(app.path) failed with status \(status).")
        }
    }

    /// Writes `<build>/install-failed`.
    func writeInstallFailed(_ text: String, in folder: URL) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: folder.appendingPathComponent(Self.installFailedName), options: .atomic)
        } catch {
            log("Writing \(Self.installFailedName) failed: \(error.localizedDescription)")
        }
    }

    /// Removes `com.apple.quarantine` from the app's folder and every item in it, links not followed; a missing
    /// attribute isn't an error.
    func removeQuarantine(from app: URL) {
        var paths = [app.path]
        if let enumerator = FileManager.default.enumerator(atPath: app.path) {
            for case let relative as String in enumerator {
                paths.append(app.appendingPathComponent(relative).path)
            }
        }
        for path in paths where removexattr(path, Self.quarantineAttribute, XATTR_NOFOLLOW) != 0 {
            let code = errno
            if code != ENOATTR {
                log("Removing the quarantine attribute of \(path) failed: \(String(cString: strerror(code)))")
            }
        }
    }
}
