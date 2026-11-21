import Foundation

/// The GitHub answer of `GET /repos/<owner>/<name>/releases/latest`; only the fields used.
public struct GitHubRelease: Decodable, Sendable, Hashable {
    public struct Asset: Decodable, Sendable, Hashable {
        public var name: String
        public var browserDownloadURL: URL

        public init(name: String, browserDownloadURL: URL) {
            self.name = name
            self.browserDownloadURL = browserDownloadURL
        }

        private enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    public var tagName: String
    public var assets: [Asset]

    public init(tagName: String, assets: [Asset]) {
        self.tagName = tagName
        self.assets = assets
    }

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }
}

/// The outcome of a feed request.
public enum FeedResult: Sendable, Equatable {
    /// The repository has no release yet.
    case noRelease
    case release(ReleaseManifest, manifestData: Data, diskImageURL: URL)
}

/// The release feed: GitHub's REST API, without signing in (docs/updater.md › Release feed).
public struct ReleaseFeed: Sendable {
    /// The repository whose releases are the app's: `Azavech/HephaestusV3`.
    public static let repository = "Azavech/HephaestusV3"
    public static let manifestAssetName = "release.json"
    /// The time limit of each request.
    public static let timeout: TimeInterval = 30
    /// The largest `release.json` read, 1 MiB.
    public static let manifestSizeLimit = 1_048_576

    public var repository: String
    public var session: URLSession
    /// The running app's version, sent in `User-Agent`.
    public var runningVersion: String

    public init(repository: String = ReleaseFeed.repository, session: URLSession, runningVersion: String) {
        self.repository = repository
        self.session = session
        self.runningVersion = runningVersion
    }

    /// A session without cache or cookies.
    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    public var latestReleaseURL: URL { URL(string: "https://api.github.com/repos/\(repository)/releases/latest")! }
    public var repositoryURL: URL { URL(string: "https://api.github.com/repos/\(repository)")! }

    /// A request of the API: its headers and time limit (docs/updater.md › Requests).
    func apiRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeout)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    var userAgent: String { "HephaestusV3-Updater/\(runningVersion)" }

    /// The latest release, its assets and its `release.json`. Every failure is an `UpdaterError` whose message is
    /// the `error` state's.
    public func latest() async throws(UpdaterError) -> FeedResult {
        let (data, status, response) = try await get(latestReleaseURL)
        switch status {
        case 200:
            break
        case 404:
            // No release yet, or a repository GitHub doesn't show to visitors: its page tells them apart.
            return try await noRelease()
        default:
            throw Self.failure(status, response)
        }
        let release: GitHubRelease
        do {
            release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch {
            throw UpdaterError(UpdaterTexts.checkFailed(error))
        }
        let manifestURL = try Self.asset(named: Self.manifestAssetName, in: release)
        let manifestData = try await downloadManifest(from: manifestURL)
        let manifest: ReleaseManifest
        do {
            manifest = try JSONDecoder().decode(ReleaseManifest.self, from: manifestData)
            try manifest.validate()
        } catch {
            throw UpdaterError(UpdaterTexts.invalidManifest)
        }
        let diskImageURL = try Self.asset(named: manifest.diskImageName, in: release)
        return .release(manifest, manifestData: manifestData, diskImageURL: diskImageURL)
    }

    /// After a 404 for the latest release: the repository's page answers 200 when it has no release yet, 404
    /// when GitHub doesn't show it to visitors.
    private func noRelease() async throws(UpdaterError) -> FeedResult {
        let (_, status, response) = try await get(repositoryURL)
        switch status {
        case 200: return .noRelease
        case 404: throw UpdaterError(UpdaterTexts.repositoryHidden(repository))
        default: throw Self.failure(status, response)
        }
    }

    private func get(_ url: URL) async throws(UpdaterError) -> (Data, Int, URLResponse) {
        do {
            let (data, response) = try await session.data(for: apiRequest(url))
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0, response)
        } catch {
            throw UpdaterError(UpdaterTexts.checkFailed(error))
        }
    }

    /// 429, or 403 with `x-ratelimit-remaining: 0`: the rate limit; any other status: `GitHub answered HTTP <n>.`
    static func failure(_ status: Int, _ response: URLResponse) -> UpdaterError {
        if status == 429 || (status == 403 && rateLimitExhausted(response)) {
            return UpdaterError(UpdaterTexts.rateLimit)
        }
        return UpdaterError(UpdaterTexts.httpStatus(status))
    }

    /// The URL of the only asset named `name`; an asset whose URL isn't HTTPS counts as missing.
    static func asset(named name: String, in release: GitHubRelease) throws(UpdaterError) -> URL {
        let matches = release.assets.filter { $0.name == name }
        guard matches.count == 1, let url = matches.first?.browserDownloadURL, url.scheme?.lowercased() == "https" else {
            throw UpdaterError(UpdaterTexts.missingAsset(name))
        }
        return url
    }

    /// Downloads `release.json`: redirects followed, at most 1 MiB.
    func downloadManifest(from url: URL) async throws(UpdaterError) -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeout)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw UpdaterError(UpdaterTexts.checkFailed(error))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            bytes.task.cancel()
            throw UpdaterError(UpdaterTexts.httpStatus(status))
        }
        guard response.expectedContentLength <= Int64(Self.manifestSizeLimit) else {
            bytes.task.cancel()
            throw UpdaterError(UpdaterTexts.invalidManifest)
        }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > Self.manifestSizeLimit {
                    bytes.task.cancel()
                    throw UpdaterError(UpdaterTexts.invalidManifest)
                }
            }
        } catch let error as UpdaterError {
            throw error
        } catch {
            throw UpdaterError(UpdaterTexts.checkFailed(error))
        }
        return data
    }

    /// 403 with `x-ratelimit-remaining: 0`.
    static func rateLimitExhausted(_ response: URLResponse) -> Bool {
        let value = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "x-ratelimit-remaining")
        return value?.trimmingCharacters(in: .whitespaces) == "0"
    }
}
