import FileStorage
import Foundation

/// One macOS version for virtual machines, as ipsw.me lists it.
public struct MacOSVersion: Sendable, Hashable, Identifiable {
    /// `27.2.1`.
    public let version: String
    /// `26B131`.
    public let build: String
    /// The Apple URL of the IPSW.
    public let url: String
    /// 0 when ipsw.me gives none.
    public let sizeBytes: Int64
    /// Lowercase, 64 hexadecimal digits; nil when ipsw.me gives none.
    public let sha256: String?

    public var id: String { build }

    public init(version: String, build: String, url: String, sizeBytes: Int64, sha256: String?) {
        self.version = version
        self.build = build
        self.url = url
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
    }
}

/// The macOS versions for virtual machines that ipsw.me lists (docs/data.md › Virtual machines › macOS versions).
public enum MacOSVersions {
    public static let listURL = URL(string: "https://api.ipsw.me/v4/device/VirtualMac2,1?type=ipsw")!
    public static let timeout: TimeInterval = 30

    public struct ListError: Error, Sendable, Hashable {
        /// `The macOS versions cannot be read from ipsw.me: <reason>.`
        public let message: String

        init(_ reason: String) {
            var reason = reason.split(whereSeparator: \.isNewline).joined(separator: " ")
            while reason.hasSuffix(".") { reason.removeLast() }
            message = "The macOS versions cannot be read from ipsw.me: \(reason)."
        }
    }

    /// Asks ipsw.me for the list.
    public static func fetch(session: URLSession = .shared) async throws(ListError) -> [MacOSVersion] {
        var request = URLRequest(url: listURL, timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ListError(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw ListError("HTTP \(http.statusCode)") }
        guard let versions = parse(data) else { throw ListError("unexpected answer") }
        return versions
    }

    /// The elements of `firmwares` with a `version`, a `buildid` and an `https` `url`, the first of each build,
    /// newest first: by version number by number, then by `releasedate`, the latest first. Nil for anything but
    /// a JSON object with a `firmwares` array.
    public static func parse(_ data: Data) -> [MacOSVersion]? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let elements = object["firmwares"] as? [Any] else { return nil }
        var builds: Set<String> = []
        var found: [(version: MacOSVersion, released: Date, index: Int)] = []
        for (index, element) in elements.enumerated() {
            guard let members = element as? [String: Any],
                  let version = members["version"] as? String, !version.isEmpty,
                  let build = members["buildid"] as? String, !build.isEmpty,
                  let text = members["url"] as? String, let url = URL(string: text),
                  url.scheme?.lowercased() == "https", url.host?.isEmpty == false,
                  builds.insert(build).inserted else { continue }
            let size = (members["filesize"] as? NSNumber)?.int64Value ?? 0
            let released = (members["releasedate"] as? String).flatMap(ISODate.date(from:)) ?? .distantPast
            found.append((MacOSVersion(version: version, build: build, url: text, sizeBytes: max(0, size), sha256: sha256(members["sha256sum"])),
                          released, index))
        }
        found.sort { first, second in
            let order = compare(first.version.version, second.version.version)
            if order != .orderedSame { return order == .orderedDescending }
            if first.released != second.released { return first.released > second.released }
            return first.index < second.index
        }
        return found.map(\.version)
    }

    private static func sha256(_ value: Any?) -> String? {
        guard let text = (value as? String)?.lowercased(), text.count == 64, text.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return text
    }

    /// Number by number: `27.2.1` is after `27.2`, `27.2` after `26.6.2`; a part that isn't a number counts as 0.
    public static func compare(_ first: String, _ second: String) -> ComparisonResult {
        let left = first.split(separator: ".").map { Int($0) ?? 0 }
        let right = second.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}
