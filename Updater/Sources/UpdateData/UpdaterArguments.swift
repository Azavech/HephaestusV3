import Foundation

/// The Updater's command line (docs/updater.md › Command line):
/// `HephaestusUpdater --app <path> --pid <pid> --interval <minutes> --auto-update <true|false>`.
public struct UpdaterArguments: Sendable, Hashable {
    public static let usageExitStatus: Int32 = 64
    public static let defaultInterval = 30

    /// The running app's absolute path.
    public var appPath: String
    /// The running app's process id.
    public var pid: Int32
    /// Minutes between two checks, 5 to 1440.
    public var intervalMinutes: Int
    public var autoUpdate: Bool

    public init(appPath: String, pid: Int32, intervalMinutes: Int = UpdaterArguments.defaultInterval, autoUpdate: Bool = true) {
        self.appPath = appPath
        self.pid = pid
        self.intervalMinutes = Self.clampInterval(intervalMinutes)
        self.autoUpdate = autoUpdate
    }

    /// The Updater writes `HephaestusUpdater: <reason>` to standard error and ends with status 64.
    public struct UsageError: Error, Equatable, Sendable, CustomStringConvertible {
        public var reason: String
        public var message: String { "HephaestusUpdater: \(reason)" }
        public var description: String { message }
    }

    /// Parses the arguments after the executable's name.
    public static func parse(_ arguments: [String]) throws(UsageError) -> UpdaterArguments {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let name = arguments[index]
            guard ["--app", "--pid", "--interval", "--auto-update"].contains(name) else { throw UsageError(reason: "unknown argument \(name)") }
            guard values[name] == nil else { throw UsageError(reason: "\(name) is given twice") }
            guard index + 1 < arguments.count else { throw UsageError(reason: "\(name) needs a value") }
            values[name] = arguments[index + 1]
            index += 2
        }
        guard let appPath = values["--app"] else { throw UsageError(reason: "--app is required") }
        guard appPath.hasPrefix("/") else { throw UsageError(reason: "--app needs an absolute path") }
        guard let pidText = values["--pid"] else { throw UsageError(reason: "--pid is required") }
        guard isDecimal(pidText), let pid = Int32(pidText), pid > 0 else { throw UsageError(reason: "--pid needs a process id") }
        var interval = defaultInterval
        if let text = values["--interval"] {
            // Below 5, a negative value included, reads as 5; too large for `Int`, as 1440.
            let digits = text.hasPrefix("-") ? String(text.dropFirst()) : text
            guard isDecimal(digits) else { throw UsageError(reason: "--interval needs a number of minutes") }
            interval = Int(text) ?? (text.hasPrefix("-") ? 5 : 1440)
        }
        var autoUpdate = true
        if let text = values["--auto-update"] {
            switch text {
            case "true": autoUpdate = true
            case "false": autoUpdate = false
            default: throw UsageError(reason: "--auto-update needs true or false")
            }
        }
        return UpdaterArguments(appPath: appPath, pid: pid, intervalMinutes: interval, autoUpdate: autoUpdate)
    }

    /// Raised to 5, lowered to 1440.
    public static func clampInterval(_ minutes: Int) -> Int {
        min(max(minutes, 5), 1440)
    }

    private static func isDecimal(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy { (0x30...0x39).contains($0) }
    }
}
