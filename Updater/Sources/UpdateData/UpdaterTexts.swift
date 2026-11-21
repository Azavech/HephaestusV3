import Foundation

/// The messages of docs/updater.md: the reasons the Updater doesn't run, and what it reports. Like the other data
/// targets' messages, they are English; the windows' own texts are in ToolsScenes' String Catalog.
public enum UpdaterTexts {
    // docs/updater.md › Starting the Updater
    public static let developmentBuild = "Updates are off in development builds."
    public static let disabledByEnvironment = "Updates are off: HEPHAESTUS_DISABLE_UPDATER is set."
    public static let notInApplications =
        "Updates are unavailable: Hephaestus V3 updates only its copy in /Applications. Move it there and open it again."
    public static let folderNotWritable = "Updates are unavailable: this account can't write to /Applications/HephaestusV3.app."
    public static let updaterMissing = "Updates are unavailable: the Updater is missing from the app."
    // docs/updater.md › Launch and supervision
    public static let stoppedUnexpectedly = "The Updater stopped unexpectedly."

    // docs/updater.md › Release feed
    public static let rateLimit = "GitHub's rate limit was reached; the next check tries again."
    public static let invalidManifest = "The release.json of the latest release is invalid."

    /// The repository's page answers 404 to a visitor.
    public static func repositoryHidden(_ repository: String) -> String {
        "GitHub doesn't show \(repository) to visitors: the repository is private or doesn't exist."
    }

    static func missingAsset(_ name: String) -> String {
        "The latest release has no \(name) asset."
    }

    static func httpStatus(_ status: Int) -> String {
        "GitHub answered HTTP \(status)."
    }

    static func checkFailed(_ error: any Error) -> String {
        "The update check failed: \(UpdaterError.describe(error))."
    }

    // docs/updater.md › Download and verification
    public static let wrongSize = "The downloaded update has the wrong size."
    public static let wrongChecksum = "The downloaded update doesn't match its SHA-256 checksum."
    public static let cannotUnpack = "The downloaded update couldn't be unpacked."
    public static let noApp = "The downloaded update doesn't contain HephaestusV3.app."
    public static let invalidSignature = "The downloaded update has an invalid code signature."
    public static let otherTeam = "The downloaded update is signed by another team."

    static func cannotSave(_ error: any Error) -> String {
        "The update couldn't be saved: \(UpdaterError.describe(error))."
    }

    static func downloadFailed(_ version: AppVersion, _ error: any Error) -> String {
        "Downloading \(version.display) failed: \(UpdaterError.describe(error))."
    }

    static func notTheUpdate(_ version: AppVersion) -> String {
        "The downloaded update isn't Hephaestus V3 \(version.display)."
    }

    // docs/updater.md › Decision
    static func requiresSystem(_ version: AppVersion, _ system: String) -> String {
        "\(version.display) requires macOS \(system)."
    }

    static func installFailed(_ version: AppVersion, _ text: String) -> String {
        "Installing \(version.display) failed: \(text)"
    }

    // docs/updater.md › Installing
    public static let didNotQuit = "Hephaestus V3 didn't quit; the update waits for the next restart."
}

/// A failure whose text is the message of the `error` state.
public struct UpdaterError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
    public var errorDescription: String? { message }

    /// `<localized description>` of docs/updater.md: the error's `localizedDescription` without its final period, so
    /// that a message ends with one period.
    static func describe(_ error: any Error) -> String {
        var text = (error as NSError).localizedDescription
        if text.hasSuffix(".") {
            text.removeLast()
        }
        return text
    }
}
