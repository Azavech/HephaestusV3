import Darwin
import Foundation
import os

/// The Updater's process (docs/updater.md): `HephaestusUpdater/main.swift` calls `main()`. It parses its command line,
/// reads the running app's Info.plist once, makes the `UpdaterMachine` with the real dependencies, connects it to
/// the distributed notifications of `UpdaterIPC`, watches the app's process and runs the main run loop. It logs with
/// `os.Logger` only: standard output and error stay silent but for a usage error.
public enum UpdaterProcess {
    static let logger = Logger(subsystem: "fr.azavech.hephaestusv3.updater", category: "updater")

    /// The inputs of the machine, delivered one at a time in their order of arrival.
    enum Input: Sendable {
        case request(UpdaterRequest)
        case appExited
    }

    @MainActor
    public static func main() -> Never {
        let arguments: UpdaterArguments
        do {
            arguments = try UpdaterArguments.parse(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data((error.message + "\n").utf8))
            exit(UpdaterArguments.usageExitStatus)
        }
        // docs/updater.md › Lifetime: an app process that doesn't exist ends the Updater.
        guard processExists(arguments.pid) else {
            logger.info("The app's process \(arguments.pid) doesn't exist; the Updater ends.")
            exit(0)
        }

        let appURL = URL(fileURLWithPath: arguments.appPath, isDirectory: true)
        let infoPlist = NSDictionary(contentsOf: appURL.appendingPathComponent("Contents/Info.plist")) as? [String: Any] ?? [:]
        let running = AppVersion.running(infoPlist)
        let cacheRoot = UpdateDownloader.defaultCacheRoot()
        let tools = UpdateTools.system
        let feed = ReleaseFeed(session: ReleaseFeed.makeSession(), runningVersion: running.version)
        let downloader = UpdateDownloader(cacheRoot: cacheRoot, session: UpdateDownloader.makeSession(), tools: tools)
        let verifier = UpdateVerifier(tools: tools)
        let installer = UpdateInstaller(cacheRoot: cacheRoot, tools: tools, log: { logger.error("\($0, privacy: .public)") })
        let pid = Int(arguments.pid)
        let center = DistributedNotificationCenter.default()

        let machine = UpdaterMachine(
            arguments: arguments, runningBuild: running.build, systemVersion: ProcessInfo.processInfo.operatingSystemVersion,
            cacheRoot: cacheRoot,
            dependencies: UpdaterMachine.Dependencies(
                latest: { () async throws(UpdaterError) -> FeedResult in try await feed.latest() },
                download: { (manifest, data, url) async throws(UpdaterError) -> URL in
                    try await downloader.download(manifest, manifestData: data, diskImageURL: url)
                },
                verify: { (image, manifest) async throws(UpdaterError) -> URL in
                    try await verifier.verify(diskImage: image, manifest: manifest, runningApp: appURL)
                },
                install: { update, manifest, restart, activate in
                    await installer.install(update: update, build: manifest.build, replacing: appURL, relaunch: restart, activate: activate)
                },
                discard: { build in
                    await UpdateDownloader.deleteBuildFolder(UpdateDownloader.buildFolder(build, in: cacheRoot), tools: tools)
                },
                post: { message in
                    let notification = UpdaterIPC.notification(for: message, pid: pid)
                    center.postNotificationName(notification.name, object: UpdaterIPC.object, userInfo: notification.userInfo,
                                                deliverImmediately: true)
                },
                exit: { status in
                    logger.info("The Updater ends with status \(status).")
                    exit(status)
                },
                log: { logger.info("\($0, privacy: .public)") }
            )
        )

        let (inputs, input) = AsyncStream<Input>.makeStream(bufferingPolicy: .unbounded)
        // The observers first, then the first status (docs/updater.md › IPC).
        for name in UpdaterIPC.appToUpdater {
            center.addObserver(forName: name, object: UpdaterIPC.object, queue: nil) { notification in
                guard let request = UpdaterIPC.request(name: notification.name, userInfo: notification.userInfo, expectedPID: pid) else {
                    return
                }
                input.yield(.request(request))
            }
        }
        let exitSource = DispatchSource.makeProcessSource(identifier: arguments.pid, eventMask: .exit, queue: .main)
        exitSource.setEventHandler {
            input.yield(.appExited)
        }
        exitSource.resume()

        Task {
            await machine.start()
            // The app may have ended before the source was installed.
            if !processExists(arguments.pid) {
                input.yield(.appExited)
            }
            for await event in inputs {
                switch event {
                case .request(let request): await machine.handle(request)
                case .appExited: await machine.appExited()
                }
            }
        }
        logger.info("The Updater started for \(arguments.appPath, privacy: .public), build \(running.build).")
        withExtendedLifetime(exitSource) {
            RunLoop.main.run()
        }
        exit(0)
    }

    /// True while the process exists.
    static func processExists(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
