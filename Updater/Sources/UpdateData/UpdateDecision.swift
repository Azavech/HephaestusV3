import Foundation

/// The outcome of a check (docs/updater.md › Decision).
public enum UpdateDecision: Sendable, Equatable {
    case upToDate
    case requiresNewerSystem(ReleaseManifest)
    case previousInstallFailed(ReleaseManifest, String)
    case available(ReleaseManifest)

    /// The first row of the decision table that holds.
    /// - Parameters:
    ///   - runningBuild: the app's `CFBundleVersion`, read once at start.
    ///   - systemVersion: the running macOS version.
    ///   - installFailedText: the text of the build's `install-failed` file; nil without one.
    public static func decide(manifest: ReleaseManifest, runningBuild: Int, systemVersion: OperatingSystemVersion,
                              installFailedText: String?) -> UpdateDecision {
        if manifest.build <= runningBuild {
            return .upToDate
        }
        if compare(manifest.minimumSystemVersion, systemVersion) > 0 {
            return .requiresNewerSystem(manifest)
        }
        if let installFailedText {
            return .previousInstallFailed(manifest, installFailedText)
        }
        return .available(manifest)
    }

    /// Compares a version string with the running system's, component by component, missing components being 0:
    /// 1 when `required` is above it, -1 below, 0 equal.
    static func compare(_ required: String, _ system: OperatingSystemVersion) -> Int {
        var parts = required.split(separator: ".").map { Int($0) ?? 0 }
        while parts.count < 3 { parts.append(0) }
        let running = [system.majorVersion, system.minorVersion, system.patchVersion]
        for (lhs, rhs) in zip(parts, running) where lhs != rhs {
            return lhs > rhs ? 1 : -1
        }
        return 0
    }
}
