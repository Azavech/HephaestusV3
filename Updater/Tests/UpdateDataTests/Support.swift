import Foundation
import Synchronization
@testable import UpdateData

/// A temporary folder, removed at deinit.
final class TemporaryFolder: Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("UpdateDataTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        // A test may have made a folder read-only.
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        try? FileManager.default.removeItem(at: url)
    }

    func path(_ component: String) -> URL {
        url.appendingPathComponent(component)
    }
}

/// Answers of the stubbed HTTP server, by absolute URL; no request leaves the process. Each test uses URLs of its
/// own (a repository named after a UUID), so tests running at once never share an answer.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    enum Answer: Sendable {
        case response(status: Int, headers: [String: String], body: Data)
        case failure(URLError.Code)
    }

    private static let state = Mutex<(answers: [String: Answer], requests: [String: [URLRequest]])>(([:], [:]))

    static func set(_ url: String, status: Int = 200, headers: [String: String] = [:], body: Data = Data()) {
        state.withLock { $0.answers[url] = .response(status: status, headers: headers, body: body) }
    }

    static func fail(_ url: String, _ code: URLError.Code) {
        state.withLock { $0.answers[url] = .failure(code) }
    }

    static func requests(to url: String) -> [URLRequest] {
        state.withLock { $0.requests[url] ?? [] }
    }

    /// An ephemeral session whose requests all go to the stub.
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let key = request.url?.absoluteString ?? ""
        let answer = Self.state.withLock { state in
            state.requests[key, default: []].append(request)
            return state.answers[key] ?? .response(status: 599, headers: [:], body: Data())
        }
        switch answer {
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .response(let status, let headers, let body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: headers.merging(["Content-Length": String(body.count)]) { a, _ in a })!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

/// The tools of a test: `codesign` runs for real, `open` and `lsregister` never do; the disk image is a folder whose
/// `HephaestusV3.app` the fake copies. Every call is recorded.
final class FakeTools: Sendable {
    let calls = Mutex<[[String]]>([])
    let unregistered = Mutex<[String]>([])
    /// What `unpack` answers when it finds no app to copy: true copies nothing and succeeds.
    let unpackSucceeds: Bool

    init(unpackSucceeds: Bool = true) {
        self.unpackSucceeds = unpackSucceeds
    }

    var tools: UpdateTools {
        UpdateTools(
            run: { [self] executable, arguments in
                calls.withLock { $0.append([executable] + arguments) }
                if executable == "/usr/bin/codesign" {
                    return await ProcessRunner.run(executable, arguments)
                }
                return 0
            },
            unpack: { [self] image, destination in
                guard unpackSucceeds else { return false }
                // The "disk image" of a test is a folder beside the image file: `<image>.contents/`.
                let source = URL(fileURLWithPath: image.path + ".contents", isDirectory: true).appendingPathComponent(DiskImage.appName)
                guard FileManager.default.fileExists(atPath: source.path) else { return true }
                try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                return (try? FileManager.default.copyItem(at: source, to: destination.appendingPathComponent(DiskImage.appName))) != nil
            },
            unregister: { [self] app in
                unregistered.withLock { $0.append(app.path) }
            })
    }

    func ran(_ executable: String) -> [[String]] {
        calls.withLock { $0.filter { $0.first == executable } }
    }
}

/// Small app bundles signed ad hoc, with a test bundle id: no test bundle passes for the app.
enum TestBundle {
    static let identifier = "fr.azavech.hephaestusv3.tests"

    /// `<folder>/<name>`, whose executable is a copy of `/usr/bin/true`.
    @discardableResult
    static func make(in folder: URL, name: String = DiskImage.appName, identifier: String = TestBundle.identifier, version: String = "1.0.44",
                     build: String = "80", sign: Bool = true) async throws -> URL {
        let app = folder.appendingPathComponent(name, isDirectory: true)
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: macOS.appendingPathComponent("HephaestusV3").path)
        let info: [String: Any] = [
            "CFBundleIdentifier": identifier, "CFBundleExecutable": "HephaestusV3", "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version, "CFBundleVersion": build,
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        if sign {
            try await run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        }
        return app
    }

    /// A "disk image" for `FakeTools`: a file with some bytes, and the folder `<image>.contents/` holding `app`.
    static func image(at url: URL, holding app: URL?) throws {
        try Data("disk image \(UUID().uuidString)".utf8).write(to: url)
        let contents = URL(fileURLWithPath: url.path + ".contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        if let app {
            try FileManager.default.copyItem(at: app, to: contents.appendingPathComponent(DiskImage.appName))
        }
    }

    static func run(_ executable: String, _ arguments: [String]) async throws {
        let status = await ProcessRunner.run(executable, arguments)
        guard status == 0 else { throw UpdaterError("\(executable) exited with status \(status)") }
    }

    /// A manifest describing `file`.
    static func manifest(for file: URL, version: String = "1.0.44", build: Int = 80) throws -> ReleaseManifest {
        let size = try (FileManager.default.attributesOfItem(atPath: file.path)[.size] as! NSNumber).intValue
        return ReleaseManifest(version: version, build: build, sha256: try UpdateDownloader.sha256Hex(of: file), size: size,
                               minimumSystemVersion: "27.0", published: Date(timeIntervalSince1970: 1_795_000_000), notes: "Notes.")
    }
}

/// Waits until `condition` holds, `seconds` at most: the bound only ends a test that fails.
func eventually(_ seconds: Double = 60, _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

/// A unique repository, so that the stub's URLs are this test's.
func testRepository() -> String {
    "tests/r\(UUID().uuidString.prefix(8).lowercased())"
}

let sampleManifest = ReleaseManifest(version: "1.0.44", build: 80, sha256: String(repeating: "a", count: 64), size: 1234,
                                     minimumSystemVersion: "27.0", published: Date(timeIntervalSince1970: 1_795_000_000), notes: "Notes.")
