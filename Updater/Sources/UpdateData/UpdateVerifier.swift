import Foundation
import Security

/// Steps 5 to 9 of docs/updater.md › Download and verification: the copy out of the disk image, the bundle, its
/// Info.plist, its signature and its Team ID.
public struct UpdateVerifier: Sendable {
    /// The bundle id an update must have; tests use their own, so that no test bundle passes for the app.
    public var bundleIdentifier: String
    public var tools: UpdateTools
    /// Reads the Team ID a bundle is signed with; nil without one (ad-hoc or unsigned).
    public var teamIDReader: @Sendable (URL) -> String?

    public static let appBundleIdentifier = "fr.azavech.hephaestusv3"

    public init(bundleIdentifier: String = UpdateVerifier.appBundleIdentifier, tools: UpdateTools = .system,
                teamIDReader: @escaping @Sendable (URL) -> String? = { UpdateVerifier.signingTeamID(of: $0) }) {
        self.bundleIdentifier = bundleIdentifier
        self.tools = tools
        self.teamIDReader = teamIDReader
    }

    /// Verifies the disk image of `<build>/` and returns `<build>/expanded/HephaestusV3.app`. A failure throws the
    /// step's `UpdaterError`; the caller deletes `<build>/`.
    public func verify(diskImage: URL, manifest: ReleaseManifest, runningApp: URL) async throws(UpdaterError) -> URL {
        let manager = FileManager.default
        let app = UpdateDownloader.expandedApp(in: diskImage.deletingLastPathComponent())
        let expanded = app.deletingLastPathComponent()

        // Step 5: a fresh `expanded/`, the app copied out of the image.
        if manager.fileExists(atPath: expanded.path) {
            await tools.unregister(app)
            do {
                try manager.removeItem(at: expanded)
            } catch {
                throw UpdaterError(UpdaterTexts.cannotUnpack)
            }
        }
        guard await tools.unpack(diskImage, expanded) else { throw UpdaterError(UpdaterTexts.cannotUnpack) }

        // Step 6: `expanded/HephaestusV3.app` is a folder, not a link to one.
        guard (try? manager.attributesOfItem(atPath: app.path))?[.type] as? FileAttributeType == .typeDirectory else {
            throw UpdaterError(UpdaterTexts.noApp)
        }

        // Step 7: the bundle id, the version and the build.
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any] ?? [:]
        guard info["CFBundleIdentifier"] as? String == bundleIdentifier,
              info["CFBundleShortVersionString"] as? String == manifest.version,
              info["CFBundleVersion"] as? String == String(manifest.build) else {
            throw UpdaterError(UpdaterTexts.notTheUpdate(manifest.appVersion))
        }

        // Step 8: the signature.
        guard await tools.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) == 0 else {
            throw UpdaterError(UpdaterTexts.invalidSignature)
        }

        // Step 9: a running app signed with a Team ID takes only an update signed with the same one.
        if let required = teamIDReader(runningApp), teamIDReader(app) != required {
            throw UpdaterError(UpdaterTexts.otherTeam)
        }
        return app
    }

    /// The Team ID of a signed bundle, read with the Security framework; nil without one.
    public static func signingTeamID(of url: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else { return nil }
        let value = dictionary[kSecCodeInfoTeamIdentifier as String] as? String
        return value?.isEmpty == false ? value : nil
    }
}
