import Foundation
import Testing
@testable import UpdateData

@Suite("Download and verification")
struct DownloadVerifyTests {
    let repository = testRepository()
    var imageURL: URL { URL(string: "https://github.com/\(repository)/releases/download/v1.0.44/HephaestusV3-1.0.44.dmg")! }

    /// A release's image whose "contents" hold `app`, served by the stub; its manifest.
    func served(_ folder: TemporaryFolder, app: URL?) throws -> (manifest: ReleaseManifest, image: URL) {
        let source = folder.path("source.dmg")
        try TestBundle.image(at: source, holding: app)
        StubProtocol.set(imageURL.absoluteString, body: try Data(contentsOf: source))
        return (try TestBundle.manifest(for: source), source)
    }

    func downloader(_ folder: TemporaryFolder, _ tools: FakeTools) -> UpdateDownloader {
        UpdateDownloader(cacheRoot: folder.path("Caches/Updates"), session: StubProtocol.session(), tools: tools.tools)
    }

    /// The download puts the image under the build's folder; the fake's contents sit beside the source image.
    func linkContents(of source: URL, to image: URL) throws {
        try FileManager.default.createSymbolicLink(atPath: image.path + ".contents", withDestinationPath: source.path + ".contents")
    }

    @Test("Steps 1 to 9: the build's folder alone, the image, release.json, the verified app")
    func success() async throws {
        let folder = try TemporaryFolder()
        let tools = FakeTools()
        let app = try await TestBundle.make(in: folder.path("built"))
        let (manifest, source) = try served(folder, app: app)
        let stale = folder.path("Caches/Updates/79")
        try FileManager.default.createDirectory(at: stale.appendingPathComponent("expanded/HephaestusV3.app"), withIntermediateDirectories: true)

        let image = try await downloader(folder, tools).download(manifest, manifestData: Data("{}".utf8), diskImageURL: imageURL)
        #expect(image == folder.path("Caches/Updates/80/HephaestusV3-1.0.44.dmg"))
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(tools.unregistered.withLock { $0 } == [stale.appendingPathComponent("expanded/HephaestusV3.app").path])
        #expect(try Data(contentsOf: folder.path("Caches/Updates/80/release.json")) == Data("{}".utf8))

        try linkContents(of: source, to: image)
        let verifier = UpdateVerifier(bundleIdentifier: TestBundle.identifier, tools: tools.tools, teamIDReader: { _ in nil })
        let verified = try await verifier.verify(diskImage: image, manifest: manifest, runningApp: folder.path("Applications/HephaestusV3.app"))
        #expect(verified == folder.path("Caches/Updates/80/expanded/HephaestusV3.app"))
        #expect(tools.ran("/usr/bin/codesign") == [["/usr/bin/codesign", "--verify", "--deep", "--strict", verified.path]])
    }

    @Test("A complete image is used again, without a request")
    func reuse() async throws {
        let folder = try TemporaryFolder()
        let (manifest, source) = try served(folder, app: nil)
        let build = folder.path("Caches/Updates/80")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: build.appendingPathComponent("HephaestusV3-1.0.44.dmg"))
        _ = try await downloader(folder, FakeTools()).download(manifest, manifestData: Data(), diskImageURL: imageURL)
        #expect(StubProtocol.requests(to: imageURL.absoluteString).isEmpty)
    }

    @Test("Steps 2 to 4 fail: an HTTP error, the size, the checksum")
    func downloadFailures() async throws {
        let folder = try TemporaryFolder()
        var (manifest, _) = try served(folder, app: nil)
        let downloader = downloader(folder, FakeTools())

        StubProtocol.set(imageURL.absoluteString, status: 404)
        await #expect(throws: UpdaterError("Downloading v1.0.44(80) failed: The server answered HTTP 404.")) {
            try await downloader.download(manifest, manifestData: Data(), diskImageURL: imageURL)
        }
        _ = try served(folder, app: nil)
        manifest.size += 1
        await #expect(throws: UpdaterError(UpdaterTexts.wrongSize)) {
            try await downloader.download(manifest, manifestData: Data(), diskImageURL: imageURL)
        }
        manifest.size -= 1
        manifest.sha256 = String(repeating: "0", count: 64)
        await #expect(throws: UpdaterError(UpdaterTexts.wrongChecksum)) {
            try await downloader.download(manifest, manifestData: Data(), diskImageURL: imageURL)
        }
    }

    /// Verifies an image whose contents hold `app` (or nothing).
    func verify(_ app: URL?, in folder: TemporaryFolder, tools: FakeTools = FakeTools(), identifier: String = TestBundle.identifier,
                teamIDs: @escaping @Sendable (URL) -> String? = { _ in nil }) async throws(UpdaterError) -> URL {
        let build = folder.path("Caches/Updates/80")
        try? FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        let image = build.appendingPathComponent("HephaestusV3-1.0.44.dmg")
        try? FileManager.default.removeItem(at: image)
        try? FileManager.default.removeItem(atPath: image.path + ".contents")
        try? TestBundle.image(at: image, holding: app)
        let manifest = try! TestBundle.manifest(for: image)
        let verifier = UpdateVerifier(bundleIdentifier: identifier, tools: tools.tools, teamIDReader: teamIDs)
        return try await verifier.verify(diskImage: image, manifest: manifest, runningApp: folder.path("Applications/HephaestusV3.app"))
    }

    @Test("Steps 5 to 9 fail")
    func verifyFailures() async throws {
        let folder = try TemporaryFolder()
        await #expect(throws: UpdaterError(UpdaterTexts.cannotUnpack)) { try await verify(nil, in: folder, tools: FakeTools(unpackSucceeds: false)) }
        await #expect(throws: UpdaterError(UpdaterTexts.noApp)) { try await verify(nil, in: folder) }

        let other = try await TestBundle.make(in: folder.path("other"), identifier: "fr.azavech.other")
        await #expect(throws: UpdaterError("The downloaded update isn't Hephaestus V3 v1.0.44(80).")) { try await verify(other, in: folder) }
        let older = try await TestBundle.make(in: folder.path("older"), build: "79")
        await #expect(throws: UpdaterError("The downloaded update isn't Hephaestus V3 v1.0.44(80).")) { try await verify(older, in: folder) }
        #expect(UpdateVerifier().bundleIdentifier == "fr.azavech.hephaestusv3")

        let tampered = try await TestBundle.make(in: folder.path("tampered"))
        try Data("changed".utf8).write(to: tampered.appendingPathComponent("Contents/MacOS/HephaestusV3"))
        await #expect(throws: UpdaterError(UpdaterTexts.invalidSignature)) { try await verify(tampered, in: folder) }

        let signed = try await TestBundle.make(in: folder.path("signed"))
        let running = folder.path("Applications/HephaestusV3.app").path
        await #expect(throws: UpdaterError(UpdaterTexts.otherTeam)) {
            try await verify(signed, in: folder, teamIDs: { $0.path == running ? "USWJAJULN9" : "OTHERTEAM1" })
        }
        _ = try await verify(signed, in: folder, teamIDs: { _ in "USWJAJULN9" })
        // An ad-hoc signed running app takes any valid signature.
        _ = try await verify(signed, in: folder, teamIDs: { $0.path == running ? nil : "OTHERTEAM1" })
        #expect(UpdateVerifier.signingTeamID(of: signed) == nil)
    }

    @Test("A real disk image: hdiutil mounts it hidden, ditto copies its app, the image is detached")
    func diskImage() async throws {
        let folder = try TemporaryFolder()
        let staging = folder.path("staging")
        let app = try await TestBundle.make(in: staging)
        try FileManager.default.createSymbolicLink(atPath: staging.appendingPathComponent("Applications").path, withDestinationPath: "/Applications")
        let image = folder.path("HephaestusV3-1.0.44.dmg")
        try await TestBundle.run("/usr/bin/hdiutil", ["create", "-quiet", "-volname", "Hephaestus V3 Tests", "-srcfolder", staging.path,
                                                      "-format", "UDZO", image.path])
        let calls = FakeTools()
        let expanded = folder.path("80/expanded")
        let copied = await DiskImage.copyApp(from: image, to: expanded) { executable, arguments in
            calls.calls.withLock { $0.append([executable] + arguments) }
            // LaunchServices is never touched by a test.
            return executable == LaunchServices.lsregister ? 0 : await ProcessRunner.run(executable, arguments)
        }
        #expect(copied)
        let info = NSDictionary(contentsOf: expanded.appendingPathComponent("HephaestusV3.app/Contents/Info.plist"))
        #expect(info?["CFBundleIdentifier"] as? String == TestBundle.identifier)
        #expect(await ProcessRunner.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", expanded.appendingPathComponent("HephaestusV3.app").path]) == 0)
        #expect(!FileManager.default.fileExists(atPath: folder.path("80/mount").path))
        let attach = try #require(calls.ran("/usr/bin/hdiutil").first)
        #expect(attach.contains("-nobrowse") && attach.contains("-readonly") && attach.contains("-noautoopen"))
        #expect(calls.ran(LaunchServices.lsregister) == [[LaunchServices.lsregister, "-u", folder.path("80/mount/HephaestusV3.app").path]])
        _ = app
        // A file that isn't a disk image doesn't mount.
        let junk = folder.path("junk.dmg")
        try Data("junk".utf8).write(to: junk)
        #expect(await DiskImage.copyApp(from: junk, to: folder.path("81/expanded"), run: { await ProcessRunner.run($0, $1) }) == false)
    }
}

/// The installer's bundles aren't named `.app`: `replaceItemAt` registers a swapped app in LaunchServices, and no test
/// may leave an entry there.
@Suite("Installer")
struct InstallerTests {
    func bundle(in folder: URL, build: String = "80") async throws -> URL {
        try await TestBundle.make(in: folder, name: "HephaestusV3.testbundle", build: build, sign: false)
    }

    @Test("The swap: the new app in place, no backup, no quarantine, the relaunch by path, the cache folder gone")
    func install() async throws {
        let folder = try TemporaryFolder()
        let cache = folder.path("Caches/Updates")
        let applications = folder.path("Applications")
        let installed = try await bundle(in: applications, build: "78")
        let update = try await bundle(in: cache.appendingPathComponent("80/expanded"))
        _ = setxattr(update.path, UpdateInstaller.quarantineAttribute, "0081;00000000;Tests;", 20, 0, XATTR_NOFOLLOW)
        let tools = FakeTools()
        let installer = UpdateInstaller(cacheRoot: cache, environment: ["HEPHAESTUS_DATA_DIR": "/tmp/x", "HOME": "/Users/x"], tools: tools.tools)

        #expect(await installer.install(update: update, build: 80, replacing: installed, relaunch: true, activate: false) == .installed)
        let info = NSDictionary(contentsOf: installed.appendingPathComponent("Contents/Info.plist"))
        #expect(info?["CFBundleVersion"] as? String == "80")
        #expect(try FileManager.default.contentsOfDirectory(atPath: applications.path) == ["HephaestusV3.testbundle"])
        #expect(getxattr(installed.path, UpdateInstaller.quarantineAttribute, nil, 0, 0, XATTR_NOFOLLOW) == -1)
        #expect(!FileManager.default.fileExists(atPath: cache.appendingPathComponent("80").path))
        #expect(tools.unregistered.withLock { $0 } == [update.path, update.path], "Before the swap, and again once the cache is gone")
        #expect(tools.ran("/usr/bin/open") == [["/usr/bin/open", "-g", "--env", "HEPHAESTUS_DATA_DIR=/tmp/x", installed.path]])
    }

    @Test("An install on quit doesn't relaunch")
    func installOnQuit() async throws {
        let folder = try TemporaryFolder()
        let installed = try await bundle(in: folder.path("Applications"), build: "78")
        let update = try await bundle(in: folder.path("Caches/Updates/80/expanded"))
        let tools = FakeTools()
        let installer = UpdateInstaller(cacheRoot: folder.path("Caches/Updates"), environment: [:], tools: tools.tools)
        #expect(await installer.install(update: update, build: 80, replacing: installed, relaunch: false, activate: false) == .installed)
        #expect(tools.ran("/usr/bin/open").isEmpty)
        #expect(installer.relaunchArguments(app: installed, activate: true) == [installed.path])
    }

    @Test("A failed swap: install-failed, the unchanged app opened again")
    func failure() async throws {
        let folder = try TemporaryFolder()
        let cache = folder.path("Caches/Updates")
        let installed = try await bundle(in: folder.path("Applications"), build: "78")
        let missing = cache.appendingPathComponent("80/expanded/HephaestusV3.testbundle")
        let tools = FakeTools()
        let installer = UpdateInstaller(cacheRoot: cache, environment: [:], tools: tools.tools)
        guard case .failed(let text) = await installer.install(update: missing, build: 80, replacing: installed, relaunch: true, activate: true) else {
            Issue.record("installed")
            return
        }
        #expect(try String(contentsOf: cache.appendingPathComponent("80/install-failed"), encoding: .utf8) == text)
        #expect(tools.ran("/usr/bin/open") == [["/usr/bin/open", installed.path]])
        #expect(NSDictionary(contentsOf: installed.appendingPathComponent("Contents/Info.plist"))?["CFBundleVersion"] as? String == "78")
    }
}
