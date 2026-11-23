import Darwin
import ExternalTools
import Foundation
import Synchronization

/// How the app reaches an environment's Kafka (docs/data.md › Kafka): the brokers this Mac reaches, and the SASL
/// user and password when the listener asks for them.
public struct KafkaConnection: Sendable, Hashable {
    public var brokers: [String]
    public var username: String?
    public var password: String?
    public var tls: Bool

    public init(brokers: [String], username: String? = nil, password: String? = nil, tls: Bool = false) {
        self.brokers = brokers
        self.username = username
        self.password = password
        self.tls = tls
    }

    /// librdkafka's properties, as kcat's `-F` file takes them: `SASL_SSL`, `SASL_PLAINTEXT`, `SSL` or `PLAINTEXT`
    /// by the user and TLS; SCRAM-SHA-512, Strimzi's KafkaUser mechanism, with a user; the system's CA certificates
    /// with TLS.
    public var properties: String {
        var lines = ["bootstrap.servers=\(brokers.joined(separator: ","))"]
        let sasl = !(username ?? "").isEmpty
        lines.append("security.protocol=\(sasl ? (tls ? "SASL_SSL" : "SASL_PLAINTEXT") : (tls ? "SSL" : "PLAINTEXT"))")
        if sasl {
            lines.append("sasl.mechanisms=SCRAM-SHA-512")
            lines.append("sasl.username=\(username ?? "")")
            lines.append("sasl.password=\(password ?? "")")
        }
        if tls { lines.append("ssl.ca.location=probe") }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// A topic and its partitions, as the brokers' metadata gives them.
public struct KafkaTopic: Sendable, Hashable, Identifiable {
    public var name: String
    public var partitions: Int

    public var id: String { name }

    public init(name: String, partitions: Int) {
        self.name = name
        self.partitions = partitions
    }

    /// Kafka's own topics, such as `__consumer_offsets`, start with `_`: All Topics leaves them out.
    public var isInternal: Bool { name.hasPrefix("_") }
}

/// One event a topic received.
public struct KafkaEvent: Sendable, Hashable, Identifiable {
    public var topic: String
    public var partition: Int
    public var offset: Int64
    /// When the producer made it, or when the broker appended it; nil when kcat gives none.
    public var timestamp: Date?
    public var key: String?
    public var value: String?
    /// The headers in their order; a header may repeat.
    public var headers: [KafkaHeader]

    public var id: String { "\(topic)/\(partition)/\(offset)" }

    public init(topic: String, partition: Int, offset: Int64, timestamp: Date? = nil, key: String? = nil, value: String? = nil,
                headers: [KafkaHeader] = []) {
        self.topic = topic
        self.partition = partition
        self.offset = offset
        self.timestamp = timestamp
        self.key = key
        self.value = value
        self.headers = headers
    }
}

public struct KafkaHeader: Sendable, Hashable {
    public var name: String
    public var value: String?

    public init(name: String, value: String?) {
        self.name = name
        self.value = value
    }
}

/// Why kcat couldn't do what was asked, in English, as its own message says it.
public struct KafkaError: Error, Sendable, Hashable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }

    public static let noKcat = KafkaError("kcat isn't installed: install it with Homebrew, brew install kcat.")
}

/// Kafka through kcat, Kafka's command-line client (the user's choice, 22 November 2026): each run gets the connection
/// in a properties file of its own, mode 0600, removed after it, so that the password is never an argument.
public struct Kcat: Sendable {
    public let path: String
    public let environment: [String: String]
    public let runner: any ProcessRunning
    /// Where the properties files go: `<data folder>/Runtime/kafka`.
    public let folder: URL

    public init(path: String, environment: [String: String], runner: any ProcessRunning, folder: URL) {
        self.path = path
        self.environment = environment
        self.runner = runner
        self.folder = folder
    }

    /// How long a listing or a read may take.
    public static let timeout: Duration = .seconds(20)
    /// What a read gives at most, over all its topics.
    public static let readLimit = 500
    /// The topics a read of every topic covers at most.
    public static let readTopicLimit = 50

    // MARK: Topics

    /// The cluster's topics, sorted by name: `kcat -L -J`.
    public func topics(_ connection: KafkaConnection) async throws(KafkaError) -> [KafkaTopic] {
        let output = try await run(["-L", "-J", "-m", "15"], connection: connection)
        return try Self.parseTopics(output)
    }

    static func parseTopics(_ data: Data) throws(KafkaError) -> [KafkaTopic] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let topics = object["topics"] as? [[String: Any]] else {
            throw KafkaError("kcat's metadata couldn't be read.")
        }
        return topics.compactMap { topic -> KafkaTopic? in
            guard let name = topic["topic"] as? String else { return nil }
            return KafkaTopic(name: name, partitions: (topic["partitions"] as? [Any])?.count ?? 0)
        }.sorted { $0.name < $1.name }
    }

    // MARK: Reading

    /// The last `last` events of each partition of each topic, oldest first, at most `readLimit` in all:
    /// `kcat -C -J -e -o -<last> -t <topic>`, one topic after the other.
    public func read(_ connection: KafkaConnection, topics: [String], last: Int) async throws(KafkaError) -> [KafkaEvent] {
        var events: [KafkaEvent] = []
        for topic in topics {
            let output = try await run(["-C", "-J", "-e", "-q", "-o", "-\(max(1, last))", "-t", topic], connection: connection)
            events += Self.parseEvents(output)
        }
        events.sort { ($0.timestamp ?? .distantPast, $0.topic, $0.partition, $0.offset) < ($1.timestamp ?? .distantPast, $1.topic, $1.partition, $1.offset) }
        return Array(events.suffix(Self.readLimit))
    }

    static func parseEvents(_ data: Data) -> [KafkaEvent] {
        String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { parseEvent(Substring($0)) }
    }

    /// One line of `kcat -J`: `topic`, `partition`, `offset`, `ts` (milliseconds), `key`, `payload`, and `headers`, a
    /// flat list of names and values.
    static func parseEvent(_ line: Substring) -> KafkaEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let topic = object["topic"] as? String, let partition = (object["partition"] as? NSNumber)?.intValue,
              let offset = (object["offset"] as? NSNumber)?.int64Value else { return nil }
        var headers: [KafkaHeader] = []
        if let flat = object["headers"] as? [Any] {
            var index = 0
            while index + 1 < flat.count {
                headers.append(KafkaHeader(name: flat[index] as? String ?? "", value: flat[index + 1] as? String))
                index += 2
            }
        }
        let milliseconds = (object["ts"] as? NSNumber)?.doubleValue
        return KafkaEvent(topic: topic, partition: partition, offset: offset,
                          timestamp: milliseconds.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil },
                          key: object["key"] as? String, value: object["payload"] as? String, headers: headers)
    }

    // MARK: Spying

    /// What a spy reads.
    public enum Selection: Sendable, Hashable {
        /// Every topic but Kafka's own, those created while it runs included.
        case all
        case topics([String])

        /// kcat's subscription: the names, or a pattern.
        var arguments: [String] {
            switch self {
            case .all: [Kcat.allTopicsPattern]
            case .topics(let names): names
            }
        }
    }

    /// Every topic whose name doesn't start with `_`.
    public static let allTopicsPattern = "^[^_].*"

    /// Starts a spy on topics: a consumer of a group of its own that commits nothing, reading from now, or from the
    /// beginning of each partition: `kcat -G <group> -J -u -q -X enable.auto.commit=false -X auto.offset.reset=…`.
    public func spy(_ connection: KafkaConnection, selection: Selection, fromBeginning: Bool) throws(KafkaError) -> KafkaSpy {
        let config = try writeProperties(connection)
        let group = "hephaestus-spy-" + UUID().uuidString.prefix(8).lowercased()
        let arguments = ["-F", config.path, "-G", group, "-J", "-u", "-q", "-X", "enable.auto.commit=false",
                         "-X", "auto.offset.reset=\(fromBeginning ? "earliest" : "latest")"] + selection.arguments
        let request = ProcessRequest(executable: path, arguments: arguments, environment: environment,
                                     standardInput: .null, standardOutput: .pipe, standardError: .pipe)
        do {
            return try KafkaSpy(process: ChildProcess.spawn(request), config: config)
        } catch {
            try? FileManager.default.removeItem(at: config)
            throw KafkaError("kcat couldn't start: \(error)")
        }
    }

    // MARK: Runs

    private func run(_ arguments: [String], connection: KafkaConnection) async throws(KafkaError) -> Data {
        let config = try writeProperties(connection)
        defer { try? FileManager.default.removeItem(at: config) }
        let request = ProcessRequest(executable: path, arguments: ["-F", config.path] + arguments, environment: environment,
                                     standardInput: .null, standardOutput: .pipe, standardError: .pipe)
        let result: ProcessResult
        do {
            result = try await runner.run(request, input: nil, timeout: Self.timeout)
        } catch {
            throw KafkaError("kcat couldn't run: \(error)")
        }
        if result.timedOut { throw KafkaError("kcat didn't answer within 20 seconds: are the brokers reachable?") }
        guard result.termination.isSuccess else {
            throw KafkaError(Self.message(result.standardError) ?? "kcat failed.")
        }
        return result.standardOutput
    }

    /// A line of kcat's standard error as a problem worth showing, or nil: its errors (`% ERROR: `, `% FATAL: `) and
    /// librdkafka's logs of level 0 to 3 (`%3|<time>|FAIL|<client>| [<thread>]: <text>`), as their text alone. Its
    /// notes, such as "% Reading configuration from file …", and its warnings, such as a deprecated property kcat
    /// sets itself, are left out.
    static func problem(_ line: String) -> String? {
        let text = line.trimmingCharacters(in: .whitespaces)
        for mark in ["% ERROR: ", "%ERROR: ", "% FATAL: "] where text.hasPrefix(mark) {
            return String(text.dropFirst(mark.count))
        }
        guard text.count > 2, text.hasPrefix("%"), let level = text.dropFirst().first, ("0"..."3").contains(level),
              text.dropFirst(2).first == "|" else { return nil }
        if let range = text.range(of: "]: ") { return String(text[range.upperBound...]) }
        return text.split(separator: "|", maxSplits: 4).last.map(String.init)
    }

    /// The last error kcat wrote, without its `% ERROR: ` mark.
    static func message(_ standardError: Data) -> String? {
        let lines = String(decoding: standardError, as: UTF8.self).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard var line = lines.last(where: { $0.contains("ERROR") || $0.contains("FAIL") }) ?? lines.last else { return nil }
        for mark in ["% ERROR: ", "%ERROR: ", "% FATAL: "] where line.hasPrefix(mark) { line.removeFirst(mark.count) }
        return line
    }

    /// Writes the connection's properties in a file of its own, mode 0600.
    func writeProperties(_ connection: KafkaConnection) throws(KafkaError) -> URL {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = folder.appendingPathComponent("kcat-\(UUID().uuidString).properties")
            guard FileManager.default.createFile(atPath: file.path, contents: Data(connection.properties.utf8),
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw KafkaError("The connection file couldn't be written in \(folder.path).")
            }
            return file
        } catch let error as KafkaError {
            throw error
        } catch {
            throw KafkaError("The connection file couldn't be written: \(error.localizedDescription)")
        }
    }
}

/// A running spy: kcat's events as they come, its errors, and its end. Stopping it ends kcat and removes its
/// properties file.
public final class KafkaSpy: Sendable {
    public enum Update: Sendable, Hashable {
        case event(KafkaEvent)
        /// An error kcat reports and retries past, such as a broker it can't reach.
        case problem(String)
        /// kcat ended: nil when stopped, else why.
        case ended(String?)
    }

    public let updates: AsyncStream<Update>
    private let process: ChildProcess
    private let config: URL
    private let continuation: AsyncStream<Update>.Continuation
    /// The last problem kcat reported, which says why it ended when it gives up.
    private let lastProblem = LastProblem()

    final class LastProblem: Sendable {
        private let value = Mutex<String?>(nil)
        func set(_ problem: String) { value.withLock { $0 = problem } }
        var current: String? { value.withLock { $0 } }
    }

    /// The spies running, so the app ends them when it quits: kcat runs in a process group of its own.
    private static let running = Mutex<[ObjectIdentifier: KafkaSpy]>([:])

    /// Ends every spy, as the app quits.
    public static func stopAll() {
        let spies = running.withLock { Array($0.values) }
        for spy in spies { spy.stop() }
    }

    /// How many spies run.
    public static var runningCount: Int { running.withLock { $0.count } }

    init(process: ChildProcess, config: URL) {
        self.process = process
        self.config = config
        let (updates, continuation) = AsyncStream.makeStream(of: Update.self, bufferingPolicy: .bufferingNewest(10_000))
        self.updates = updates
        self.continuation = continuation
        let output = process.standardOutput
        let errors = process.standardError
        let lastProblem = lastProblem
        Task.detached(priority: .utility) {
            if let errors {
                for try await line in errors.bytes.lines {
                    guard let problem = Kcat.problem(line) else { continue }
                    lastProblem.set(problem)
                    continuation.yield(.problem(problem))
                }
            }
        }
        let id = ObjectIdentifier(self)
        Self.running.withLock { $0[id] = self }
        Task.detached(priority: .userInitiated) { [process, config] in
            if let output {
                do {
                    for try await line in output.bytes.lines {
                        if let event = Kcat.parseEvent(Substring(line)) { continuation.yield(.event(event)) }
                    }
                } catch {}
            }
            let termination = await process.waitForExit()
            try? FileManager.default.removeItem(at: config)
            KafkaSpy.running.withLock { _ = $0.removeValue(forKey: id) }
            // kcat's own reason when it gave up, such as every broker down; its status otherwise.
            try? await Task.sleep(for: .milliseconds(100))
            let reason = lastProblem.current ?? "kcat ended: \(termination)."
            continuation.yield(.ended(termination.isSuccess || termination == .signaled(SIGTERM) ? nil : reason))
            continuation.finish()
        }
    }

    /// Ends kcat: it leaves its group, which commits nothing.
    public func stop() {
        guard !process.hasExited else { return }
        process.signalGroup(SIGTERM)
    }
}
