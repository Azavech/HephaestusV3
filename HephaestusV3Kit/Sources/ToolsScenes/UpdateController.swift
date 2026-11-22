import AppKit
import ExternalTools
import FileStorage
import Foundation
import Observation
import ProjectData
import UpdateData

/// What a restart for an update would stop or lose (docs/ui/updates.md › Restart rules): the app is idle when it is
/// all zero.
struct RunningWork: Equatable {
    /// The chats the status bar counts: at work, waiting for the user, or with background work.
    var chats = 0
    /// The virtual machines, setups and installs that run, and the images that download or install.
    var machines = 0
    /// Whether an existing chat holds unsent text or files.
    var drafts = false
    /// Whether a window shows a sheet.
    var sheet = false

    var isIdle: Bool { chats == 0 && machines == 0 && !drafts && !sheet }
}

/// The app side of the Updater (docs/updater.md, docs/ui/updates.md): starts and watches the helper, posts `check`,
/// `install` and `app.quitting`, keeps its last status, and restarts the app to install an update, by itself when
/// the app is idle or when the user chooses Install.
@MainActor @Observable
final class UpdateController {
    /// The last status of the Updater; `idle` until the first one.
    private(set) var status = UpdaterStatus.initial
    /// Why the Updater doesn't run; nil while it runs.
    private(set) var unavailableReason: String?
    /// The app waits for the answer to its last `check`.
    private(set) var awaitingCheck = false
    /// No status came within 15 seconds after the last `check`.
    private(set) var checkTimedOut = false
    /// The install mark, one for the app: Install, the Update item or Update Now, until the app quits.
    private(set) var installChosen = false
    /// A restart for the update didn't happen, and the update stays.
    private(set) var restartFailed = false
    /// The restart runs: `app.quitting` was posted.
    private(set) var restartInProgress = false
    /// `settings.yml`'s `autoUpdate` and `updateCheckIntervalMinutes`, as last sent to the Updater.
    private(set) var autoUpdate = true
    private(set) var intervalMinutes = SettingsFile.defaultUpdateCheckInterval

    /// The running app's version and build.
    let appVersion: AppVersion
    /// The repository the releases come from.
    let repository = ReleaseFeed.repository

    /// What a restart would stop: read through observation, so that the automatic restart follows it.
    @ObservationIgnored var runningWork: () -> RunningWork = { RunningWork() }
    @ObservationIgnored private let bundleURL: URL
    @ObservationIgnored private let infoPlist: [String: Any]
    @ObservationIgnored private let environment: [String: String]
    @ObservationIgnored private var dataFolder: DataFolder?
    @ObservationIgnored private let pid = Int(ProcessInfo.processInfo.processIdentifier)
    /// True once this launch started an Updater: only then does the app read its notifications and post
    /// `app.quitting`.
    @ObservationIgnored private(set) var started = false
    @ObservationIgnored private var process: ChildProcess?
    @ObservationIgnored private var restarts = 0
    @ObservationIgnored private var quittingPosted = false
    @ObservationIgnored private var restartChecksRunning = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var checkTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var idleRecheckTask: Task<Void, Never>?
    @ObservationIgnored private var installingWaiter: CheckedContinuation<Bool, Never>?
    /// The build whose restart didn't happen: the app doesn't restart for it by itself again.
    @ObservationIgnored private var blockedBuild: Int?

    /// docs/updater.md › Launch and supervision.
    static let restartDelay: Duration = .seconds(5)
    static let maximumRestarts = 3
    /// About window, row 3.
    static let checkAnswerTimeout: Duration = .seconds(15)
    /// Restart for an update, step 3.
    static let installingTimeout: Duration = .seconds(5)
    /// While the automatic restart waits, what observation doesn't see (sheets) is looked at again this often.
    static let idleRecheck: Duration = .seconds(2)
    /// The user default that keeps the windows over a restart for an update, and the mark that the app set it.
    static let keepWindowsKey = "NSQuitAlwaysKeepsWindows"
    static let keepWindowsMarkKey = "updateRestartKeepsWindows"

    init(bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment) {
        bundleURL = bundle.bundleURL
        infoPlist = bundle.infoDictionary ?? [:]
        self.environment = environment
        appVersion = AppVersion.running(infoPlist)
    }

    // MARK: Starting the Updater

    /// At launch, once the settings are read: forgets a restart's kept windows, then starts the Updater unless a
    /// condition of docs/updater.md › Starting the Updater holds, whose reason then shows.
    func start(dataFolder: DataFolder?) {
        guard !started, unavailableReason == nil else { return }
        Self.forgetKeptWindows()
        self.dataFolder = dataFolder
        if let settings = dataFolder?.readSettings() {
            autoUpdate = settings.autoUpdate ?? true
            intervalMinutes = settings.updateCheckInterval
        }
        if let reason = UpdaterStartConditions.reason(infoPlist: infoPlist, environment: environment, bundleURL: bundleURL) {
            unavailableReason = reason
            return
        }
        started = true
        observeUpdater()
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.appWillQuit()
            }
        })
        launchUpdater()
        observeIdleness()
    }

    /// While the Updater runs, or starts again after an unexpected end.
    var isRunning: Bool { started && unavailableReason == nil }

    /// Starts `Contents/Helpers/HephaestusUpdater` in a process group of its own, with the app's environment and
    /// `/dev/null` for its standard input, output and error.
    private func launchUpdater() {
        guard isRunning, !quittingPosted, process == nil else { return }
        let request = ProcessRequest(
            executable: UpdaterStartConditions.updaterURL(bundleURL: bundleURL).path,
            arguments: ["--app", bundleURL.path, "--pid", String(pid), "--interval", String(intervalMinutes), "--auto-update", autoUpdate ? "true" : "false"],
            environment: environment, standardInput: .null, standardOutput: .null, standardError: .null)
        do {
            let child = try ChildProcess.spawn(request)
            process = child
            Task { [weak self] in
                let termination = await child.waitForExit()
                self?.updaterExited(termination)
            }
        } catch {
            // A start that fails counts as an end.
            updaterExited(nil)
        }
    }

    /// The Updater ended while the app runs: it starts again 5 seconds later, three times at most in one launch;
    /// then its reason is `The Updater stopped unexpectedly.`
    private func updaterExited(_ termination: ProcessTermination?) {
        process = nil
        guard !quittingPosted else { return }
        guard restarts < Self.maximumRestarts else {
            unavailableReason = UpdaterTexts.stoppedUnexpectedly
            awaitingCheck = false
            checkTimeoutTask?.cancel()
            return
        }
        restarts += 1
        Task { [weak self] in
            try? await Task.sleep(for: Self.restartDelay)
            self?.launchUpdater()
        }
    }

    // MARK: IPC

    private func observeUpdater() {
        let center = DistributedNotificationCenter.default()
        let pid = pid
        for name in UpdaterIPC.updaterToApp {
            observers.append(center.addObserver(forName: name, object: UpdaterIPC.object, queue: .main) { [weak self] notification in
                guard let message = UpdaterIPC.message(name: notification.name, userInfo: notification.userInfo, expectedPID: pid) else { return }
                MainActor.assumeIsolated {
                    self?.received(message)
                }
            })
        }
    }

    private func post(_ request: UpdaterRequest) {
        let notification = UpdaterIPC.notification(for: request, pid: pid)
        DistributedNotificationCenter.default().postNotificationName(notification.name, object: UpdaterIPC.object,
                                                                     userInfo: notification.userInfo, deliverImmediately: true)
    }

    /// Posts `check` with the current settings, while the Updater runs.
    func postCheck() {
        guard isRunning else { return }
        post(.check(intervalMinutes: intervalMinutes, autoUpdate: autoUpdate))
        awaitingCheck = true
        checkTimedOut = false
        checkTimeoutTask?.cancel()
        checkTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: Self.checkAnswerTimeout)
            guard !Task.isCancelled, let self, self.awaitingCheck else { return }
            self.checkTimedOut = true
        }
    }

    private func postInstall() {
        guard isRunning else { return }
        post(.install)
    }

    /// An ordinary quit: `app.quitting` once, without a restart, so that a `ready` update installs as the app quits.
    private func appWillQuit() {
        guard started, !quittingPosted else { return }
        quittingPosted = true
        post(.appQuitting(restart: false, activate: false))
    }

    private func received(_ message: UpdaterMessage) {
        let previous = status
        switch message {
        case .status(let new):
            status = new
        case .ready(let version, let build):
            // `ready` follows the status `ready`; it only fills in a status missed.
            guard previous.state != .ready || previous.build != build else { return }
            status = UpdaterStatus(state: .ready, version: version, build: build)
        }
        // Any status answers the last `check`.
        awaitingCheck = false
        checkTimedOut = false
        checkTimeoutTask?.cancel()
        if status.state != .ready {
            restartFailed = false
        }
        switch status.state {
        case .installing:
            resumeInstallingWaiter(true)
        case .error:
            // An error after Install clears the mark.
            installChosen = false
        case .ready where previous.state != .ready && installChosen:
            runRestartChecksAndRestart()
        default:
            break
        }
        evaluateAutomaticRestart()
    }

    // MARK: Settings ▸ Updates

    /// Stores `autoUpdate`, then tells the Updater. Throws the storage error; without a data folder the choice holds
    /// until the app quits.
    func setAutoUpdate(_ value: Bool) throws(StorageError) {
        try store { $0.autoUpdate = value }
        autoUpdate = value
        postCheck()
        evaluateAutomaticRestart()
    }

    /// Stores `updateCheckIntervalMinutes`, then tells the Updater.
    func setIntervalMinutes(_ value: Int) throws(StorageError) {
        try store { $0.updateCheckIntervalMinutes = value }
        intervalMinutes = min(max(value, UpdateInterval.range.lowerBound), UpdateInterval.range.upperBound)
        postCheck()
    }

    private func store(_ change: (inout SettingsFile) -> Void) throws(StorageError) {
        guard let dataFolder else { return }
        var settings = dataFolder.readSettings()
        change(&settings)
        // Both keys are written together, as Settings ▸ Notifications writes its three.
        settings.autoUpdate = settings.autoUpdate ?? autoUpdate
        settings.updateCheckIntervalMinutes = settings.updateCheckIntervalMinutes ?? intervalMinutes
        try dataFolder.writeSettings(settings)
    }

    // MARK: About window, Settings ▸ Updates and the Update item

    /// The About window appeared: `check`, while the Updater runs.
    func aboutWindowAppeared() {
        postCheck()
    }

    func aboutArea(notNowClicked: Bool) -> UpdateArea {
        UpdateArea.about(areaInput(notNowClicked: notNowClicked))
    }

    var settingsStatusLine: UpdateArea {
        UpdateArea.settingsStatusLine(areaInput(notNowClicked: false))
    }

    private func areaInput(notNowClicked: Bool) -> UpdateArea.Input {
        UpdateArea.Input(unavailableReason: unavailableReason, installChosen: installChosen, checkTimedOut: checkTimedOut,
                         awaitingCheck: awaitingCheck, status: status, notNowClicked: notNowClicked, restartFailed: restartFailed)
    }

    var updateItem: UpdateItem? {
        UpdateItem.item(updaterRunning: isRunning, status: status, autoUpdate: autoUpdate, installChosen: installChosen,
                        restartInProgress: restartInProgress)
    }

    var updateNowVisible: Bool {
        UpdateItem.updateNowVisible(updaterRunning: isRunning, status: status, installChosen: installChosen, restartInProgress: restartInProgress)
    }

    /// Install, a click on the Update item, Update Now: marks the install as chosen; in `ready` the restart checks run
    /// at once, in `available` the app posts `install`, otherwise they run when `ready` arrives.
    func install() {
        guard isRunning, !installChosen, !restartInProgress else { return }
        installChosen = true
        restartFailed = false
        switch status.state {
        case .ready: runRestartChecksAndRestart()
        case .available: postInstall()
        default: break
        }
    }

    /// Try Again: `install` when the error carries a build, `check` otherwise.
    func tryAgain() {
        if status.state == .error, status.build != nil, !checkTimedOut {
            postInstall()
        } else {
            postCheck()
        }
    }

    // MARK: Restart

    /// The restart checks, then the restart. Cancel clears the Install mark; the update stays `ready`.
    private func runRestartChecksAndRestart() {
        guard !restartChecksRunning, !restartInProgress, status.state == .ready else { return }
        let version = status.appVersion ?? appVersion
        restartChecksRunning = true
        let confirmed = Self.confirmRestart(to: version, work: runningWork())
        restartChecksRunning = false
        guard confirmed, status.state == .ready else {
            installChosen = false
            evaluateAutomaticRestart()
            return
        }
        Task { [weak self] in
            await self?.restart()
        }
    }

    /// When the restart would stop chats or virtual machines, or lose drafts, asks first: `Restart to install
    /// v1.0.44(80)?`. True to go on.
    private static func confirmRestart(to version: AppVersion, work: RunningWork) -> Bool {
        let message = restartMessage(work)
        guard !message.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = String(localized: "Restart to install \(version.display)?", bundle: #bundle,
                                   comment: "The alert before a restart for an update; the version, such as v1.0.44(80)")
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "Restart", bundle: #bundle, comment: "The button that restarts the app to install an update"))
        alert.addButton(withTitle: String(localized: "Cancel", bundle: #bundle))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// `2 chats will be stopped. 1 virtual machine will be stopped. Unsent drafts will be lost.`, the parts that
    /// apply; empty when the app is idle but for a sheet.
    static func restartMessage(_ work: RunningWork) -> String {
        var parts: [String] = []
        if work.chats > 0 {
            parts.append(String(AttributedString(localized: "^[\(work.chats) chat](inflect: true) will be stopped.", bundle: #bundle,
                                                 comment: "The restart alert: the chats at work or waiting").characters))
        }
        if work.machines > 0 {
            parts.append(String(AttributedString(localized: "^[\(work.machines) virtual machine](inflect: true) will be stopped.", bundle: #bundle,
                                                 comment: "The restart alert: the machines, setups, installs and image downloads").characters))
        }
        if work.drafts {
            parts.append(String(localized: "Unsent drafts will be lost.", bundle: #bundle, comment: "The restart alert: chats hold drafts"))
        }
        return parts.joined(separator: " ")
    }

    /// docs/updater.md › Restart for an update, steps 1 to 3 (the app's side): macOS keeps the windows, the app posts
    /// `app.quitting` with `restart`, waits 5 seconds at most for `installing`, then quits. Without an answer it
    /// keeps running and says so in an alert.
    private func restart() async {
        guard started, !restartInProgress, !quittingPosted else { return }
        let build = status.build
        restartInProgress = true
        idleRecheckTask?.cancel()
        Self.keepWindows()
        quittingPosted = true
        post(.appQuitting(restart: true, activate: NSApp.isActive))
        if await waitForInstalling() {
            QuitConfirmation.confirmed = true
            NSApp.terminate(nil)
            return
        }
        // The restart doesn't happen: the next quit closes the windows as the user chose.
        Self.forgetKeptWindows()
        quittingPosted = false
        restartInProgress = false
        installChosen = false
        restartFailed = true
        blockedBuild = build
        if process == nil {
            updaterExited(nil)
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "The Updater didn't answer; the update wasn't installed.", bundle: #bundle)
        alert.addButton(withTitle: String(localized: "OK", bundle: #bundle))
        alert.runModal()
    }

    private func waitForInstalling() async -> Bool {
        if status.state == .installing { return true }
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: Self.installingTimeout)
            guard !Task.isCancelled else { return }
            self?.resumeInstallingWaiter(false)
        }
        let answered = await withCheckedContinuation { continuation in
            installingWaiter = continuation
        }
        timeout.cancel()
        return answered
    }

    private func resumeInstallingWaiter(_ answered: Bool) {
        guard let waiter = installingWaiter else { return }
        installingWaiter = nil
        waiter.resume(returning: answered)
    }

    /// macOS keeps the windows over this quit, whatever System Settings say: the app's own
    /// `NSQuitAlwaysKeepsWindows`, with a mark so that the next launch removes only what the app set.
    private static func keepWindows() {
        let defaults = UserDefaults.standard
        guard defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[keepWindowsKey] == nil else { return }
        defaults.set(true, forKey: keepWindowsKey)
        defaults.set(true, forKey: keepWindowsMarkKey)
    }

    private static func forgetKeptWindows() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: keepWindowsMarkKey) else { return }
        defaults.removeObject(forKey: keepWindowsKey)
        defaults.removeObject(forKey: keepWindowsMarkKey)
    }

    // MARK: Automatic restart

    private func evaluateAutomaticRestart() {
        idleRecheckTask?.cancel()
        idleRecheckTask = nil
        let decision = AutomaticRestart.decide(updaterRunning: isRunning, autoUpdate: autoUpdate, installChosen: installChosen,
                                               restartChecksRunning: restartChecksRunning, restartInProgress: restartInProgress,
                                               quittingPosted: quittingPosted, status: status, blockedBuild: blockedBuild,
                                               idle: runningWork().isIdle)
        switch decision {
        case .notApplicable:
            break
        case .startsNow:
            Task { [weak self] in
                await self?.restart()
            }
        case .waitsForIdle:
            idleRecheckTask = Task { [weak self] in
                try? await Task.sleep(for: Self.idleRecheck)
                guard !Task.isCancelled else { return }
                self?.evaluateAutomaticRestart()
            }
        }
    }

    /// Evaluates the automatic restart again whenever what `runningWork` reads changes.
    private func observeIdleness() {
        withObservationTracking {
            _ = runningWork()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.evaluateAutomaticRestart()
                self.observeIdleness()
            }
        }
    }
}
