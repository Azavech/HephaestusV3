import Foundation
import Testing
@testable import UpdateData

@Suite("Versions")
struct VersionTests {
    @Test("Info.plist values, display, and the build comparison")
    func versions() {
        let version = AppVersion(infoPlist: ["CFBundleShortVersionString": "1.0.43", "CFBundleVersion": "78"])
        #expect(version == AppVersion(version: "1.0.43", build: 78))
        #expect(version?.display == "v1.0.43(78)")
        #expect(version?.aboutLine == "Version 1.0.43 (78)")
        #expect(AppVersion(infoPlist: ["CFBundleVersion": "1.2"]) == nil)
        #expect(AppVersion(infoPlist: ["CFBundleVersion": ""]) == nil)
        #expect(AppVersion(infoPlist: [:]) == nil)
        #expect(AppVersion(infoPlist: ["CFBundleVersion": "7"])?.version == "")
        #expect(AppVersion.running(["CFBundleShortVersionString": "1.0"]) == AppVersion(version: "1.0", build: 0))
        #expect(AppVersion(version: "1.0.44", build: 80).isNewer(than: AppVersion(version: "9.9.9", build: 79)))
        #expect(!AppVersion(version: "2.0.0", build: 78).isNewer(than: AppVersion(version: "1.0.43", build: 78)))
    }
}

@Suite("release.json")
struct ManifestTests {
    @Test("The example of docs/release.md decodes and passes its rules")
    func docsExample() throws {
        let docs = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../docs/release.md").standardizedFileURL
        let text = try String(contentsOf: docs, encoding: .utf8)
        let blocks = text.components(separatedBy: "```json\n").dropFirst().map { $0.components(separatedBy: "```").first ?? "" }
        #expect(blocks.count == 1)
        let manifest = try JSONDecoder().decode(ReleaseManifest.self, from: Data(try #require(blocks.first).utf8))
        try manifest.validate()
        #expect(manifest.diskImageName == "HephaestusV3-\(manifest.version).dmg")
    }

    @Test("Round trip, unknown members ignored")
    func roundTrip() throws {
        let data = try JSONEncoder().encode(sampleManifest)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["published"] as? String == "2026-11-18T11:06:40Z")
        object["future"] = "kept out"
        let decoded = try JSONDecoder().decode(ReleaseManifest.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded == sampleManifest)
    }

    @Test("Each rule", arguments: [
        ("version", "1.0"), ("version", "01.0.0"), ("build", "0"), ("sha256", "ABC"), ("size", "0"), ("minimumSystemVersion", "27.x"),
    ])
    func rules(field: String, value: String) {
        var manifest = sampleManifest
        switch field {
        case "version": manifest.version = value
        case "build": manifest.build = Int(value)!
        case "sha256": manifest.sha256 = value
        case "size": manifest.size = Int(value)!
        default: manifest.minimumSystemVersion = value
        }
        #expect(throws: ReleaseManifest.ValidationError(field: field)) { try manifest.validate() }
    }

    @Test("A published date in another form doesn't decode")
    func published() {
        let json = #"{"version":"1.0.44","build":80,"sha256":"\#(String(repeating: "a", count: 64))","size":1,"minimumSystemVersion":"27","published":"2026-11-18 08:53","notes":""}"#
        #expect(throws: (any Error).self) { try JSONDecoder().decode(ReleaseManifest.self, from: Data(json.utf8)) }
    }
}

@Suite("Decision")
struct DecisionTests {
    let system = OperatingSystemVersion(majorVersion: 27, minorVersion: 1, patchVersion: 0)

    @Test("Every row, in order")
    func rows() {
        #expect(UpdateDecision.decide(manifest: sampleManifest, runningBuild: 80, systemVersion: system, installFailedText: "x") == .upToDate)
        var newer = sampleManifest
        newer.minimumSystemVersion = "27.2"
        #expect(UpdateDecision.decide(manifest: newer, runningBuild: 78, systemVersion: system, installFailedText: "x") == .requiresNewerSystem(newer))
        #expect(UpdateDecision.decide(manifest: sampleManifest, runningBuild: 78, systemVersion: system, installFailedText: "Denied.")
            == .previousInstallFailed(sampleManifest, "Denied."))
        #expect(UpdateDecision.decide(manifest: sampleManifest, runningBuild: 78, systemVersion: system, installFailedText: nil) == .available(sampleManifest))
        #expect(UpdateDecision.compare("27", system) == -1)
        #expect(UpdateDecision.compare("27.1", system) == 0)
        #expect(UpdateDecision.compare("28", system) == 1)
    }
}

@Suite("Command line")
struct ArgumentTests {
    @Test("A full command line, and the interval's bounds")
    func parse() throws {
        let arguments = try UpdaterArguments.parse(["--app", "/Applications/HephaestusV3.app", "--pid", "42", "--interval", "2", "--auto-update", "false"])
        #expect(arguments == UpdaterArguments(appPath: "/Applications/HephaestusV3.app", pid: 42, intervalMinutes: 5, autoUpdate: false))
        #expect(try UpdaterArguments.parse(["--app", "/a", "--pid", "1"]).intervalMinutes == 30)
        #expect(try UpdaterArguments.parse(["--app", "/a", "--pid", "1", "--interval", "-3"]).intervalMinutes == 5)
        #expect(try UpdaterArguments.parse(["--app", "/a", "--pid", "1", "--interval", "99999999999999999999"]).intervalMinutes == 1440)
    }

    @Test("Each usage error", arguments: [
        (["--app", "/a", "--pid", "1", "--x", "y"], "unknown argument --x"),
        (["--app", "/a", "--app", "/b"], "--app is given twice"),
        (["--app"], "--app needs a value"),
        (["--pid", "1"], "--app is required"),
        (["--app", "a", "--pid", "1"], "--app needs an absolute path"),
        (["--app", "/a"], "--pid is required"),
        (["--app", "/a", "--pid", "0"], "--pid needs a process id"),
        (["--app", "/a", "--pid", "1", "--interval", "ten"], "--interval needs a number of minutes"),
        (["--app", "/a", "--pid", "1", "--auto-update", "yes"], "--auto-update needs true or false"),
    ])
    func usage(arguments: [String], reason: String) {
        #expect(throws: UpdaterArguments.UsageError(reason: reason)) { try UpdaterArguments.parse(arguments) }
        #expect(UpdaterArguments.UsageError(reason: reason).message == "HephaestusUpdater: \(reason)")
    }
}

@Suite("IPC")
struct IPCTests {
    @Test("Every notification's userInfo round trip, and the pid filter")
    func roundTrip() {
        let requests: [UpdaterRequest] = [.check(intervalMinutes: 60, autoUpdate: false), .check(intervalMinutes: nil, autoUpdate: nil), .install,
                                          .appQuitting(restart: true, activate: false)]
        for request in requests {
            let notification = UpdaterIPC.notification(for: request, pid: 42)
            #expect(UpdaterIPC.request(name: notification.name, userInfo: notification.userInfo, expectedPID: 42) == request)
            #expect(UpdaterIPC.request(name: notification.name, userInfo: notification.userInfo, expectedPID: 43) == nil)
        }
        let messages: [UpdaterMessage] = [.status(UpdaterStatus(state: .error, version: "1.0.44", build: 80, message: "No.")),
                                          .status(.initial), .ready(version: "1.0.44", build: 80)]
        for message in messages {
            let notification = UpdaterIPC.notification(for: message, pid: 42)
            #expect(UpdaterIPC.message(name: notification.name, userInfo: notification.userInfo, expectedPID: 42) == message)
            #expect(UpdaterIPC.message(name: notification.name, userInfo: notification.userInfo, expectedPID: 7) == nil)
        }
        #expect(UpdaterStatus.initial.userInfo(pid: 1).keys.sorted() == ["pid", "state"])
        #expect(UpdaterIPC.message(name: UpdaterIPC.status, userInfo: ["pid": 1, "state": "dancing"], expectedPID: 1) == nil)
        #expect(UpdaterIPC.request(name: UpdaterIPC.status, userInfo: ["pid": 1], expectedPID: 1) == nil)
        // A value of another type isn't adopted.
        #expect(UpdaterIPC.request(name: UpdaterIPC.check, userInfo: ["pid": 1, "intervalMinutes": "60", "autoUpdate": 1], expectedPID: 1)
            == .check(intervalMinutes: nil, autoUpdate: nil))
        #expect(UpdaterIPC.check.rawValue == "fr.azavech.hephaestusv3.updater.check")
        #expect(UpdaterIPC.appQuitting.rawValue == "fr.azavech.hephaestusv3.app.quitting")
    }
}

@Suite("Starting the Updater")
struct StartConditionTests {
    let release: [String: Any] = ["CFBundleShortVersionString": "1.0.43", "CFBundleVersion": "78"]

    /// `<folder>/Applications/HephaestusV3.app`, with an executable Updater when asked.
    func installed(in folder: TemporaryFolder, updater: Bool = true) throws -> URL {
        // Not named `.app`, so that LaunchServices never sees it.
        let app = folder.path("Applications/HephaestusV3.testbundle")
        let helpers = app.appendingPathComponent("Contents/Helpers")
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        if updater {
            let path = helpers.appendingPathComponent("HephaestusUpdater").path
            FileManager.default.createFile(atPath: path, contents: Data(), attributes: [.posixPermissions: 0o755])
        }
        return app
    }

    @Test("Each condition, in order")
    func conditions() throws {
        let folder = try TemporaryFolder()
        let app = try installed(in: folder)
        func reason(_ info: [String: Any] = [:], environment: [String: String] = [:], bundle: URL? = nil) -> String? {
            UpdaterStartConditions.reason(infoPlist: info.isEmpty ? release : info, environment: environment, bundleURL: bundle ?? app, installedURL: app)
        }
        #expect(reason() == nil)
        #expect(reason(["CFBundleVersion": "0"]) == UpdaterTexts.developmentBuild)
        #expect(reason(["CFBundleShortVersionString": "1.0"]) == UpdaterTexts.developmentBuild)
        #expect(reason(environment: ["HEPHAESTUS_DISABLE_UPDATER": "1"]) == UpdaterTexts.disabledByEnvironment)
        #expect(reason(environment: ["HEPHAESTUS_DISABLE_UPDATER": "0"]) == nil)
        #expect(reason(bundle: folder.path("Downloads/HephaestusV3.app")) == UpdaterTexts.notInApplications)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: app.deletingLastPathComponent().path)
        #expect(reason() == UpdaterTexts.folderNotWritable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: app.deletingLastPathComponent().path)
        try FileManager.default.removeItem(at: UpdaterStartConditions.updaterURL(bundleURL: app))
        #expect(reason() == UpdaterTexts.updaterMissing)
        #expect(UpdaterStartConditions.updaterURL(bundleURL: URL(fileURLWithPath: "/Applications/HephaestusV3.app")).path
            == "/Applications/HephaestusV3.app/Contents/Helpers/HephaestusUpdater")
    }
}

@Suite("Presentation")
struct PresentationTests {
    let update = AppVersion(version: "1.0.44", build: 80)
    func status(_ state: UpdaterState, message: String? = nil) -> UpdaterStatus {
        UpdaterStatus(state: state, version: "1.0.44", build: 80, message: message)
    }

    @Test("The About window's rows, in order")
    func aboutRows() {
        func row(_ input: UpdateArea.Input) -> UpdateArea { UpdateArea.about(input) }
        #expect(row(.init(unavailableReason: "Off.", installChosen: true)) == UpdateArea(row: 1, line: .unavailable("Off.")))
        #expect(row(.init(installChosen: true, checkTimedOut: true)) == UpdateArea(row: 2, line: .installing, showsProgress: true))
        #expect(row(.init(checkTimedOut: true, awaitingCheck: true)) == UpdateArea(row: 3, line: .notResponding, controls: .tryAgain))
        #expect(row(.init(awaitingCheck: true, status: status(.ready))) == UpdateArea(row: 4, line: .checking, showsProgress: true))
        #expect(row(.init(status: .initial)).row == 4)
        #expect(row(.init(status: UpdaterStatus(state: .checking))).row == 4)
        #expect(row(.init(status: UpdaterStatus(state: .upToDate))) == UpdateArea(row: 5, line: .noUpdate))
        #expect(row(.init(status: status(.upToDate, message: "v1.0.44(80) requires macOS 28."))) == UpdateArea(row: 6, line: .message("v1.0.44(80) requires macOS 28.")))
        for state in [UpdaterState.available, .downloading, .ready] {
            #expect(row(.init(status: status(state), notNowClicked: true)) == UpdateArea(row: 7, line: .available(update)))
            #expect(row(.init(status: status(state))) == UpdateArea(row: 8, line: .available(update), controls: .installOrNotNow))
        }
        #expect(row(.init(status: status(.ready), restartFailed: true)) == UpdateArea(row: 8, line: .restartFailed, controls: .installOrNotNow))
        #expect(row(.init(status: UpdaterStatus(state: .error, message: "Nope."))) == UpdateArea(row: 9, line: .message("Nope."), controls: .tryAgain))
        #expect(row(.init(status: status(.installing))) == UpdateArea(row: 10, line: .installing, showsProgress: true))
    }

    @Test("Settings' status line has no controls and no Not Now")
    func statusLine() {
        #expect(UpdateArea.settingsStatusLine(.init(status: status(.available), notNowClicked: true)) == UpdateArea(row: 8, line: .available(update)))
        #expect(UpdateArea.settingsStatusLine(.init(status: UpdaterStatus(state: .error, message: "No."))).controls == .none)
    }

    @Test("The Update item and Update Now")
    func updateItem() {
        func item(_ state: UpdaterState, running: Bool = true, auto: Bool = true, chosen: Bool = false, restarting: Bool = false) -> UpdateItem? {
            UpdateItem.item(updaterRunning: running, status: status(state), autoUpdate: auto, installChosen: chosen, restartInProgress: restarting)
        }
        #expect(item(.available) == .available(.available(update)))
        #expect(item(.downloading) == .available(.downloading(update)))
        #expect(item(.ready) == .available(.ready(update, restartsWhenIdle: true)))
        #expect(item(.ready, auto: false) == .available(.ready(update, restartsWhenIdle: false)))
        #expect(item(.ready, chosen: true) == .installing)
        #expect(item(.upToDate, chosen: true) == .installing)
        #expect(item(.ready, restarting: true) == nil)
        #expect(item(.ready, running: false) == nil)
        for state in [UpdaterState.idle, .checking, .upToDate, .installing, .error] {
            #expect(item(state) == nil)
        }
        #expect(UpdateItem.updateNowVisible(updaterRunning: true, status: status(.downloading), installChosen: false, restartInProgress: false))
        #expect(!UpdateItem.updateNowVisible(updaterRunning: true, status: status(.ready), installChosen: true, restartInProgress: false))
    }

    @Test("The automatic restart")
    func automaticRestart() {
        func decide(auto: Bool = true, chosen: Bool = false, state: UpdaterState = .ready, blocked: Int? = nil, idle: Bool = true) -> AutomaticRestart {
            AutomaticRestart.decide(updaterRunning: true, autoUpdate: auto, installChosen: chosen, restartChecksRunning: false,
                                    restartInProgress: false, quittingPosted: false, status: status(state), blockedBuild: blocked, idle: idle)
        }
        #expect(decide() == .startsNow)
        #expect(decide(idle: false) == .waitsForIdle)
        #expect(decide(auto: false) == .notApplicable)
        #expect(decide(chosen: true) == .notApplicable)
        #expect(decide(state: .available) == .notApplicable)
        #expect(decide(blocked: 80) == .notApplicable)
        #expect(decide(blocked: 79) == .startsNow)
    }
}
