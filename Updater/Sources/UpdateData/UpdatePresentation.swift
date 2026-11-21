import Foundation

// The app side's rules, pure functions of their inputs so that UpdateDataTests cover them: when the Updater may
// start, the About window's update area, the status bar's Update item and the automatic restart
// (docs/updater.md › Starting the Updater, docs/ui/updates.md).

/// docs/updater.md › Starting the Updater: the conditions under which the app doesn't start the Updater, in order.
public enum UpdaterStartConditions {
    /// The only copy of the app that updates itself.
    public static let installedPath = "/Applications/HephaestusV3.app"
    /// Set to `1`, it keeps the Updater from starting.
    public static let disableVariable = "HEPHAESTUS_DISABLE_UPDATER"

    /// The reason of the first condition that holds; nil when the Updater may start.
    /// - Parameters:
    ///   - infoPlist: the running app's Info.plist.
    ///   - environment: the app's environment, for `HEPHAESTUS_DISABLE_UPDATER`.
    ///   - bundleURL: the running app (`Bundle.main.bundleURL`).
    ///   - installedURL: `/Applications/HephaestusV3.app`; tests give a temporary one.
    public static func reason(infoPlist: [String: Any], environment: [String: String], bundleURL: URL,
                              installedURL: URL = URL(fileURLWithPath: installedPath, isDirectory: true),
                              fileManager: FileManager = .default) -> String? {
        // 1. A development build: `CFBundleVersion` missing, not a decimal integer, or 0.
        guard let version = AppVersion(infoPlist: infoPlist), version.build != 0 else { return UpdaterTexts.developmentBuild }
        // 2. HEPHAESTUS_DISABLE_UPDATER=1.
        if environment[disableVariable] == "1" { return UpdaterTexts.disabledByEnvironment }
        // 3. Another copy than /Applications/HephaestusV3.app.
        let bundle = bundleURL.standardizedFileURL
        guard bundle.path == installedURL.standardizedFileURL.path else { return UpdaterTexts.notInApplications }
        // 4. Its folder, or the app itself, can't be written.
        if !fileManager.isWritableFile(atPath: bundle.deletingLastPathComponent().path) || !fileManager.isWritableFile(atPath: bundle.path) {
            return UpdaterTexts.folderNotWritable
        }
        // 5. No Updater in the app.
        if !fileManager.isExecutableFile(atPath: updaterURL(bundleURL: bundle).path) { return UpdaterTexts.updaterMissing }
        return nil
    }

    /// `Contents/Helpers/HephaestusUpdater` of an app.
    public static func updaterURL(bundleURL: URL) -> URL {
        bundleURL.appendingPathComponent("Contents/Helpers/HephaestusUpdater", isDirectory: false)
    }
}

/// The update area of the About window and the status line of Settings ▸ Updates (docs/ui/updates.md).
public struct UpdateArea: Sendable, Hashable {
    /// What the line says; ToolsScenes words it.
    public enum Line: Sendable, Hashable {
        /// A reason of docs/updater.md › Starting the Updater, or `The Updater stopped unexpectedly.`
        case unavailable(String)
        case installing
        case notResponding
        case checking
        case noUpdate
        /// A message of the Updater.
        case message(String)
        /// `v1.0.44(80) available`.
        case available(AppVersion)
        /// The restart didn't happen: `The Updater didn't answer; the update wasn't installed.`
        case restartFailed
    }

    public enum Controls: Sendable, Hashable {
        case none
        case tryAgain
        /// Install (the default button) and Not Now.
        case installOrNotNow
    }

    /// The row of the About window's table that applies.
    public var row: Int
    public var line: Line
    /// A small progress indicator before the line.
    public var showsProgress: Bool
    public var controls: Controls

    public init(row: Int, line: Line, showsProgress: Bool = false, controls: Controls = .none) {
        self.row = row
        self.line = line
        self.showsProgress = showsProgress
        self.controls = controls
    }

    /// The app side's view of the Updater.
    public struct Input: Sendable, Hashable {
        /// The Updater doesn't run: the reason.
        public var unavailableReason: String?
        /// Install was chosen and the app hasn't quit.
        public var installChosen: Bool
        /// No status came within 15 seconds after the app's last `check`.
        public var checkTimedOut: Bool
        /// The app waits for the answer to its last `check`.
        public var awaitingCheck: Bool
        public var status: UpdaterStatus
        /// Not Now was clicked since the About window appeared.
        public var notNowClicked: Bool
        /// A restart for the update didn't happen, and the update stays.
        public var restartFailed: Bool

        public init(unavailableReason: String? = nil, installChosen: Bool = false, checkTimedOut: Bool = false, awaitingCheck: Bool = false,
                    status: UpdaterStatus = .initial, notNowClicked: Bool = false, restartFailed: Bool = false) {
            self.unavailableReason = unavailableReason
            self.installChosen = installChosen
            self.checkTimedOut = checkTimedOut
            self.awaitingCheck = awaitingCheck
            self.status = status
            self.notNowClicked = notNowClicked
            self.restartFailed = restartFailed
        }
    }

    /// The first row of the About window's table that holds.
    public static func about(_ input: Input) -> UpdateArea {
        if let reason = input.unavailableReason {
            return UpdateArea(row: 1, line: .unavailable(reason))
        }
        if input.installChosen {
            return UpdateArea(row: 2, line: .installing, showsProgress: true)
        }
        let status = input.status
        if input.checkTimedOut {
            return UpdateArea(row: 3, line: .notResponding, controls: .tryAgain)
        }
        if input.awaitingCheck || status.state == .idle || status.state == .checking {
            return UpdateArea(row: 4, line: .checking, showsProgress: true)
        }
        let version = AppVersion(version: status.version ?? "", build: status.build ?? 0)
        switch status.state {
        case .upToDate:
            if let message = status.message {
                return UpdateArea(row: 6, line: .message(message))
            }
            return UpdateArea(row: 5, line: .noUpdate)
        case .available, .downloading, .ready:
            let line: Line = input.restartFailed ? .restartFailed : .available(version)
            if input.notNowClicked {
                return UpdateArea(row: 7, line: line)
            }
            return UpdateArea(row: 8, line: line, controls: .installOrNotNow)
        case .error:
            return UpdateArea(row: 9, line: .message(status.message ?? ""), controls: .tryAgain)
        case .installing:
            // Row 10, which shows row 2's line.
            return UpdateArea(row: 10, line: .installing, showsProgress: true)
        case .idle, .checking:
            return UpdateArea(row: 4, line: .checking, showsProgress: true)
        }
    }

    /// The status line of Settings ▸ Updates: the About window's line and progress indicator, without controls; it
    /// has no Not Now.
    public static func settingsStatusLine(_ input: Input) -> UpdateArea {
        var input = input
        input.notNowClicked = false
        var area = about(input)
        area.controls = .none
        return area
    }
}

/// The status bar's Update item (docs/ui/updates.md › Update item).
public enum UpdateItem: Sendable, Hashable {
    /// `Update available…`, with the tooltip of its state; a click installs the update.
    case available(Tooltip)
    /// `Installing…` with a small progress indicator, no tooltip, not clickable.
    case installing

    public enum Tooltip: Sendable, Hashable {
        /// `Update v1.0.44(80) available — click to install`
        case available(AppVersion)
        /// `Downloading update v1.0.44(80)…`
        case downloading(AppVersion)
        /// `Update v1.0.44(80) ready — restarts when idle`, or without `autoUpdate`, `Update v1.0.44(80) ready`.
        case ready(AppVersion, restartsWhenIdle: Bool)
    }

    /// The states in which the Update item and Update Now offer the update.
    public static let offeredStates: Set<UpdaterState> = [.available, .downloading, .ready]

    /// While the Updater runs: `Installing…` while the install is chosen; `Update available…` in `available`,
    /// `downloading` or `ready` until the restart starts; nil, hidden, otherwise.
    public static func item(updaterRunning: Bool, status: UpdaterStatus, autoUpdate: Bool, installChosen: Bool,
                            restartInProgress: Bool) -> UpdateItem? {
        guard updaterRunning else { return nil }
        if installChosen { return .installing }
        guard !restartInProgress, offeredStates.contains(status.state) else { return nil }
        let version = AppVersion(version: status.version ?? "", build: status.build ?? 0)
        switch status.state {
        case .available: return .available(.available(version))
        case .downloading: return .available(.downloading(version))
        default: return .available(.ready(version, restartsWhenIdle: autoUpdate))
        }
    }

    /// Settings ▸ Updates' Update Now shows exactly when the Update item offers the update.
    public static func updateNowVisible(updaterRunning: Bool, status: UpdaterStatus, installChosen: Bool, restartInProgress: Bool) -> Bool {
        guard case .available = item(updaterRunning: updaterRunning, status: status, autoUpdate: false, installChosen: installChosen,
                                     restartInProgress: restartInProgress) else { return false }
        return true
    }
}

/// What the automatic restart does now (docs/ui/updates.md › Restart rules).
public enum AutomaticRestart: Sendable, Hashable {
    /// No update waits for an automatic restart.
    case notApplicable
    /// The restart waits until the app is idle.
    case waitsForIdle
    /// The restart starts now.
    case startsNow

    /// State `ready`, `autoUpdate` on, Install not chosen: the restart starts as soon as the app is idle, without an
    /// alert, unless a restart for this build didn't happen or one already runs.
    public static func decide(updaterRunning: Bool, autoUpdate: Bool, installChosen: Bool, restartChecksRunning: Bool,
                              restartInProgress: Bool, quittingPosted: Bool, status: UpdaterStatus, blockedBuild: Int?,
                              idle: @autoclosure () -> Bool) -> AutomaticRestart {
        guard updaterRunning, autoUpdate, !installChosen, !restartChecksRunning, !restartInProgress, !quittingPosted,
              status.state == .ready, let build = status.build, build != blockedBuild else { return .notApplicable }
        return idle() ? .startsNow : .waitsForIdle
    }
}

/// The interval choices of Settings ▸ Updates, in minutes.
public enum UpdateInterval {
    public static let choices = [15, 30, 60, 120, 360, 1440]
    public static let defaultMinutes = UpdaterArguments.defaultInterval
    public static let range = 5...1440
}
