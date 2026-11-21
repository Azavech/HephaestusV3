import Foundation
import Testing
@testable import UpdateData

@Suite("Release feed")
struct ReleaseFeedTests {
    let repository = testRepository()
    var feed: ReleaseFeed { ReleaseFeed(repository: repository, session: StubProtocol.session(), runningVersion: "1.0.43") }
    var latest: String { "https://api.github.com/repos/\(repository)/releases/latest" }
    var page: String { "https://api.github.com/repos/\(repository)" }
    var manifestURL: String { "https://github.com/\(repository)/releases/download/v1.0.44/release.json" }
    var imageURL: String { "https://github.com/\(repository)/releases/download/v1.0.44/HephaestusV3-1.0.44.dmg" }

    func release(assets: [(String, String)]) -> Data {
        let list = assets.map { #"{"name":"\#($0.0)","browser_download_url":"\#($0.1)","size":1}"# }.joined(separator: ",")
        return Data(#"{"tag_name":"v1.0.44","name":"Hephaestus V3 1.0.44 (80)","assets":[\#(list)]}"#.utf8)
    }

    /// Encoded once: JSONEncoder's member order may change from one call to the next.
    let manifestData = try! JSONEncoder().encode(sampleManifest)

    @Test("A release: its release.json and its disk image, with the API's headers")
    func release() async throws {
        StubProtocol.set(latest, body: release(assets: [("release.json", manifestURL), ("HephaestusV3-1.0.44.dmg", imageURL)]))
        StubProtocol.set(manifestURL, body: manifestData)
        let result = try await feed.latest()
        #expect(result == .release(sampleManifest, manifestData: manifestData, diskImageURL: URL(string: imageURL)!))
        let request = try #require(StubProtocol.requests(to: latest).first)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "HephaestusV3-Updater/1.0.43")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.timeoutInterval == 30)
    }

    @Test("404, then the repository's page: 200 is no release yet")
    func noRelease() async throws {
        StubProtocol.set(latest, status: 404)
        StubProtocol.set(page, body: Data("{}".utf8))
        #expect(try await feed.latest() == .noRelease)
    }

    @Test("404, then 404 for the page: the repository is private or missing")
    func hidden() async {
        StubProtocol.set(latest, status: 404)
        StubProtocol.set(page, status: 404)
        await #expect(throws: UpdaterError(UpdaterTexts.repositoryHidden(repository))) { try await feed.latest() }
        #expect(UpdaterTexts.repositoryHidden(ReleaseFeed.repository)
            == "GitHub doesn't show Azavech/HephaestusV3 to visitors: the repository is private or doesn't exist.")
    }

    @Test("The rate limit, another status, no answer")
    func failures() async {
        StubProtocol.set(latest, status: 403, headers: ["x-ratelimit-remaining": "0"])
        await #expect(throws: UpdaterError(UpdaterTexts.rateLimit)) { try await feed.latest() }
        StubProtocol.set(latest, status: 429)
        await #expect(throws: UpdaterError(UpdaterTexts.rateLimit)) { try await feed.latest() }
        StubProtocol.set(latest, status: 403, headers: ["x-ratelimit-remaining": "12"])
        await #expect(throws: UpdaterError("GitHub answered HTTP 403.")) { try await feed.latest() }
        StubProtocol.set(latest, status: 500)
        await #expect(throws: UpdaterError("GitHub answered HTTP 500.")) { try await feed.latest() }
        StubProtocol.set(latest, status: 404)
        StubProtocol.set(page, status: 502)
        await #expect(throws: UpdaterError("GitHub answered HTTP 502.")) { try await feed.latest() }
        StubProtocol.fail(latest, .notConnectedToInternet)
        do {
            _ = try await feed.latest()
            Issue.record("no error")
        } catch {
            #expect(error.message.hasPrefix("The update check failed: "))
            #expect(error.message.hasSuffix(".") && !error.message.hasSuffix(".."))
        }
    }

    @Test("Missing or insecure assets, and an invalid release.json")
    func assets() async {
        StubProtocol.set(latest, body: release(assets: [("HephaestusV3-1.0.44.dmg", imageURL)]))
        await #expect(throws: UpdaterError("The latest release has no release.json asset.")) { try await feed.latest() }
        StubProtocol.set(latest, body: release(assets: [("release.json", "http://example.com/release.json"), ("HephaestusV3-1.0.44.dmg", imageURL)]))
        await #expect(throws: UpdaterError("The latest release has no release.json asset.")) { try await feed.latest() }
        StubProtocol.set(latest, body: release(assets: [("release.json", manifestURL)]))
        StubProtocol.set(manifestURL, body: manifestData)
        await #expect(throws: UpdaterError("The latest release has no HephaestusV3-1.0.44.dmg asset.")) { try await feed.latest() }
        StubProtocol.set(latest, body: release(assets: [("release.json", manifestURL), ("HephaestusV3-1.0.44.dmg", imageURL)]))
        StubProtocol.set(manifestURL, body: Data(#"{"version":"1.0"}"#.utf8))
        await #expect(throws: UpdaterError(UpdaterTexts.invalidManifest)) { try await feed.latest() }
        StubProtocol.set(manifestURL, body: Data(count: ReleaseFeed.manifestSizeLimit + 1))
        await #expect(throws: UpdaterError(UpdaterTexts.invalidManifest)) { try await feed.latest() }
        StubProtocol.set(manifestURL, status: 503)
        await #expect(throws: UpdaterError("GitHub answered HTTP 503.")) { try await feed.latest() }
        StubProtocol.set(latest, body: Data("[]".utf8))
        do {
            _ = try await feed.latest()
            Issue.record("no error")
        } catch {
            #expect(error.message.hasPrefix("The update check failed: "))
        }
    }

    @Test("The app's repository")
    func repositoryOfTheApp() {
        #expect(ReleaseFeed.repository == "Azavech/HephaestusV3")
        let feed = ReleaseFeed(session: StubProtocol.session(), runningVersion: "1.0.43")
        #expect(feed.latestReleaseURL.absoluteString == "https://api.github.com/repos/Azavech/HephaestusV3/releases/latest")
    }
}
