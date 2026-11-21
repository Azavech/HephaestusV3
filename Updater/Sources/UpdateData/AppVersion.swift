import Foundation

/// The version and build of the app or of a release (docs/updater.md › Versions). Only builds are compared;
/// version strings are shown and checked for equality.
public struct AppVersion: Sendable, Hashable, Codable {
    /// `CFBundleShortVersionString`, `X.Y.Z`.
    public var version: String
    /// `CFBundleVersion`, a decimal integer: the number of commits of the release.
    public var build: Int

    public init(version: String, build: Int) {
        self.version = version
        self.build = build
    }

    /// Reads `CFBundleShortVersionString` and `CFBundleVersion`; nil when `CFBundleVersion` is missing or not a
    /// decimal integer. A missing `CFBundleShortVersionString` reads as `""`.
    public init?(infoPlist: [String: Any]) {
        guard let build = Self.decimalBuild(infoPlist["CFBundleVersion"]) else { return nil }
        version = infoPlist["CFBundleShortVersionString"] as? String ?? ""
        self.build = build
    }

    /// The running app's: its build is 0 when `CFBundleVersion` doesn't read.
    public static func running(_ infoPlist: [String: Any]) -> AppVersion {
        AppVersion(infoPlist: infoPlist) ?? AppVersion(version: infoPlist["CFBundleShortVersionString"] as? String ?? "", build: 0)
    }

    /// `v<version>(<build>)`, such as `v1.0.43(78)`: the status bar's Version item and the update texts.
    public var display: String { "v\(version)(\(build))" }

    /// `Version <version> (<build>)`, such as `Version 1.0.43 (78)`: the About window and Settings ▸ Updates.
    public var aboutLine: String { "Version \(version) (\(build))" }

    /// True when this build is greater than `other`'s.
    public func isNewer(than other: AppVersion) -> Bool {
        build > other.build
    }

    /// A string of decimal digits that fits in `Int`, or a non-negative `Int`.
    static func decimalBuild(_ value: Any?) -> Int? {
        if let text = value as? String {
            guard !text.isEmpty, text.utf8.allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
            return Int(text)
        }
        if let number = value as? Int, number >= 0 {
            return number
        }
        return nil
    }
}
