import CryptoKit
import Foundation

/// Steps 1 to 4 of docs/updater.md › Download and verification: the build's cache folder, the download of its disk
/// image (or the reuse of a complete one), its size and its SHA-256.
public struct UpdateDownloader: Sendable {
    /// `~/Library/Caches/HephaestusV3/Updates/`.
    public var cacheRoot: URL
    public var session: URLSession
    public var tools: UpdateTools

    public static let manifestName = "release.json"
    /// The request's time limit.
    public static let requestTimeout: TimeInterval = 60
    /// The whole download's, 30 minutes.
    public static let resourceTimeout: TimeInterval = 30 * 60

    public init(cacheRoot: URL, session: URLSession, tools: UpdateTools = .system) {
        self.cacheRoot = cacheRoot
        self.session = session
        self.tools = tools
    }

    /// The cache folder of the updates; it doesn't move with `HEPHAESTUS_DATA_DIR`.
    public static func defaultCacheRoot(homeDirectory: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: homeDirectory, isDirectory: true).appendingPathComponent("Library/Caches/HephaestusV3/Updates", isDirectory: true)
    }

    /// A session for the disk image: no cache, 30 minutes at most.
    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        return URLSession(configuration: configuration)
    }

    /// `<cacheRoot>/<build>/`.
    public static func buildFolder(_ build: Int, in cacheRoot: URL) -> URL {
        cacheRoot.appendingPathComponent(String(build), isDirectory: true)
    }

    /// The copy of the app a build's folder holds once unpacked: `<build>/expanded/HephaestusV3.app`.
    public static func expandedApp(in folder: URL) -> URL {
        folder.appendingPathComponent("expanded", isDirectory: true).appendingPathComponent(DiskImage.appName, isDirectory: true)
    }

    /// Deletes a build's folder, after forgetting its copy of the app in LaunchServices.
    public static func deleteBuildFolder(_ folder: URL, tools: UpdateTools) async {
        await tools.unregister(expandedApp(in: folder))
        try? FileManager.default.removeItem(at: folder)
    }

    /// Runs steps 1 to 4 and returns `<build>/HephaestusV3-<version>.dmg`. A failure throws the step's
    /// `UpdaterError`; the caller deletes `<build>/`.
    public func download(_ manifest: ReleaseManifest, manifestData: Data, diskImageURL: URL) async throws(UpdaterError) -> URL {
        let version = manifest.appVersion
        let folder = Self.buildFolder(manifest.build, in: cacheRoot)
        let image = folder.appendingPathComponent(manifest.diskImageName)

        // Step 1: the build's folder; every other entry of the cache folder goes.
        do {
            try await prepare(folder)
        } catch {
            throw UpdaterError(UpdaterTexts.cannotSave(error))
        }

        // Step 2: a complete disk image is used again; otherwise it is downloaded to a temporary file, then moved.
        var digest = Self.fingerprint(of: image)
        if digest?.size != manifest.size || digest?.sha256 != manifest.sha256 {
            do {
                try await fetch(diskImageURL, to: image)
            } catch {
                throw UpdaterError(UpdaterTexts.downloadFailed(version, error))
            }
            digest = nil
        }
        do {
            try manifestData.write(to: folder.appendingPathComponent(Self.manifestName), options: .atomic)
        } catch {
            throw UpdaterError(UpdaterTexts.downloadFailed(version, error))
        }

        // Step 3: the size.
        guard (digest?.size ?? Self.fileSize(of: image)) == manifest.size else { throw UpdaterError(UpdaterTexts.wrongSize) }
        // Step 4: the SHA-256, in lowercase hexadecimal.
        guard (digest?.sha256 ?? (try? Self.sha256Hex(of: image))) == manifest.sha256 else {
            throw UpdaterError(UpdaterTexts.wrongChecksum)
        }
        return image
    }

    /// Creates `folder` and deletes every other entry of the cache folder.
    func prepare(_ folder: URL) async throws {
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in try manager.contentsOfDirectory(atPath: cacheRoot.path) where name != folder.lastPathComponent {
            let entry = cacheRoot.appendingPathComponent(name)
            await tools.unregister(Self.expandedApp(in: entry))
            try manager.removeItem(at: entry)
        }
    }

    /// Downloads `url`, redirects followed, and moves the complete file to `destination`; an answer that isn't 2xx
    /// fails.
    func fetch(_ url: URL, to destination: URL) async throws {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.requestTimeout)
        let (temporary, response) = try await session.download(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            try? FileManager.default.removeItem(at: temporary)
            throw HTTPStatusError(status: status)
        }
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            try manager.removeItem(at: destination)
        }
        try manager.moveItem(at: temporary, to: destination)
    }

    /// The size and SHA-256 of a regular file; nil when it doesn't exist or can't be read.
    static func fingerprint(of url: URL) -> (size: Int, sha256: String)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue,
              let sha256 = try? sha256Hex(of: url) else { return nil }
        return (size, sha256)
    }

    static func fileSize(of url: URL) -> Int? {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue
    }

    /// The SHA-256 of a file in lowercase hexadecimal, read 1 MiB at a time.
    public static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// A download answered with a status other than 2xx.
struct HTTPStatusError: Error, LocalizedError {
    var status: Int
    var errorDescription: String? { "The server answered HTTP \(status)." }
}
