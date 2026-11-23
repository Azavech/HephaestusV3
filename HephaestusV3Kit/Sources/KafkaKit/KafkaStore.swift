import ExternalTools
import Foundation
import KafkaData
import ProjectData
import ToolsFoundation

/// An environment of the project whose Kafka the tool reads.
public struct KafkaEnvironment: Hashable, Sendable, Identifiable {
    public var name: String
    /// `host:port`, separated by commas.
    public var brokers: String
    public var username: String?

    public var id: String { name }

    public init(name: String, brokers: String, username: String? = nil) {
        self.name = name
        self.brokers = brokers
        self.username = username
    }
}

/// A spy as the tool follows it: its updates, and how to stop it.
public struct KafkaSpyHandle: Sendable {
    public let updates: AsyncStream<KafkaSpy.Update>
    public let stop: @Sendable () -> Void

    public init(updates: AsyncStream<KafkaSpy.Update>, stop: @escaping @Sendable () -> Void) {
        self.updates = updates
        self.stop = stop
    }
}

/// Where the Kafka tool reads: the app's projects through kcat, or samples in previews and tests.
@MainActor
public protocol KafkaStore: AnyObject {
    /// False until the login shell's tools were looked up the first time.
    var hasLookedUpTools: Bool { get }
    var hasKcat: Bool { get }
    /// The project's environments with brokers, in the project's order.
    func environments(of project: Project.ID) -> [KafkaEnvironment]
    func topics(project: Project.ID, environment: String) async throws(KafkaError) -> [KafkaTopic]
    func spy(project: Project.ID, environment: String, selection: Kcat.Selection, fromBeginning: Bool) throws(KafkaError) -> KafkaSpyHandle
    /// The last events of each partition of topics, oldest first.
    func read(project: Project.ID, environment: String, topics: [String], last: Int) async throws(KafkaError) -> [KafkaEvent]
    /// Waits for the first lookup of the tools.
    func waitForTools() async
    /// Looks the tools up again, for kcat installed since.
    func lookAgain() async
}

/// The app's Kafka: each environment's brokers and user from the project files, its password from this Mac's
/// `secrets.json`, and kcat from the login shell's `PATH` (docs/data.md › Kafka).
@MainActor
public final class LiveKafkaStore: KafkaStore {
    private let session: ProjectSession
    private let runner: any ProcessRunning

    public init(session: ProjectSession, runner: any ProcessRunning = SystemProcessRunner.shared) {
        self.session = session
        self.runner = runner
    }

    public var hasLookedUpTools: Bool { session.hasLookedUpTools }
    public var hasKcat: Bool { session.tools.kcat != nil }

    public func environments(of project: Project.ID) -> [KafkaEnvironment] {
        (session.snapshot.project(project)?.resolved.environments ?? []).compactMap { entry in
            guard let brokers = entry.kafkaBrokers else { return nil }
            return KafkaEnvironment(name: entry.name, brokers: brokers, username: entry.kafkaUsername)
        }
    }

    /// The connection of an environment: its password is the project's, else the nearest parent's that has one for
    /// an environment of that name.
    func connection(project id: Project.ID, environment name: String) throws(KafkaError) -> KafkaConnection {
        guard let project = session.snapshot.project(id) else { throw KafkaError("No project \(id).") }
        guard let entry = project.resolved.environments.first(where: { $0.name == name }) else {
            throw KafkaError("\(id) has no environment \(name).")
        }
        let brokers = entry.kafkaBrokerList
        guard !brokers.isEmpty else { throw KafkaError("The environment \(name) of \(id) has no Kafka brokers.") }
        var password: String?
        if entry.kafkaUsername != nil {
            var current: LoadedProject? = project
            while let candidate = current, password == nil {
                password = session.dataFolder?.kafkaPassword(project: candidate.id, environment: name)
                current = candidate.parentID.flatMap { session.snapshot.project($0) }
            }
        }
        return KafkaConnection(brokers: brokers, username: entry.kafkaUsername, password: password, tls: entry.kafkaTLS)
    }

    func kcat() throws(KafkaError) -> Kcat {
        guard let path = session.tools.kcat else { throw .noKcat }
        let folder = (session.dataFolder?.url ?? FileManager.default.temporaryDirectory).appendingPathComponent("Runtime/kafka")
        return Kcat(path: path, environment: session.tools.environment, runner: runner, folder: folder)
    }

    public func topics(project: Project.ID, environment: String) async throws(KafkaError) -> [KafkaTopic] {
        let connection = try connection(project: project, environment: environment)
        return try await kcat().topics(connection)
    }

    public func spy(project: Project.ID, environment: String, selection: Kcat.Selection, fromBeginning: Bool) throws(KafkaError) -> KafkaSpyHandle {
        let spy = try kcat().spy(try connection(project: project, environment: environment), selection: selection, fromBeginning: fromBeginning)
        return KafkaSpyHandle(updates: spy.updates, stop: { spy.stop() })
    }

    public func read(project: Project.ID, environment: String, topics: [String], last: Int) async throws(KafkaError) -> [KafkaEvent] {
        let connection = try connection(project: project, environment: environment)
        return try await kcat().read(connection, topics: topics, last: last)
    }

    public func waitForTools() async {
        await session.waitForTools()
    }

    public func lookAgain() async {
        await session.lookUpTools()
    }
}

/// Samples for the previews: two environments, four topics, and a spy that sends a few events.
@MainActor
final class SampleKafkaStore: KafkaStore {
    var hasLookedUpTools = true
    var hasKcat = true
    var environmentsOf: [Project.ID: [KafkaEnvironment]] = ["ORD": [KafkaEnvironment(name: "Local", brokers: "localhost:9094"),
                                                                   KafkaEnvironment(name: "Staging", brokers: "kafka.staging.example.com:9093",
                                                                                    username: "hephaestus")]]
    var topicList = [KafkaTopic(name: "greetings.requested", partitions: 3), KafkaTopic(name: "greetings.requested.kafka-poc.dlq", partitions: 1),
                     KafkaTopic(name: "greetings.sent", partitions: 3), KafkaTopic(name: "orders.created", partitions: 6)]
    var events = SampleKafkaStore.sampleEvents
    var failure: KafkaError?

    init() {}

    func environments(of project: Project.ID) -> [KafkaEnvironment] { environmentsOf[project] ?? [] }

    func topics(project: Project.ID, environment: String) async throws(KafkaError) -> [KafkaTopic] {
        if let failure { throw failure }
        return topicList
    }

    func spy(project: Project.ID, environment: String, selection: Kcat.Selection, fromBeginning: Bool) throws(KafkaError) -> KafkaSpyHandle {
        if let failure { throw failure }
        let (stream, continuation) = AsyncStream.makeStream(of: KafkaSpy.Update.self)
        let chosen: [KafkaEvent] = switch selection {
        case .all: events
        case .topics(let names): events.filter { names.contains($0.topic) }
        }
        for event in chosen { continuation.yield(.event(event)) }
        return KafkaSpyHandle(updates: stream, stop: {
            continuation.yield(.ended(nil))
            continuation.finish()
        })
    }

    func read(project: Project.ID, environment: String, topics: [String], last: Int) async throws(KafkaError) -> [KafkaEvent] {
        events.filter { topics.contains($0.topic) }
    }

    func waitForTools() async {}
    func lookAgain() async {}

    static let sampleEvents: [KafkaEvent] = {
        let start = Date(timeIntervalSince1970: 1_793_455_380)
        func event(_ topic: String, _ partition: Int, _ offset: Int64, _ seconds: Double, key: String?, value: String,
                   headers: [KafkaHeader] = []) -> KafkaEvent {
            KafkaEvent(topic: topic, partition: partition, offset: offset, timestamp: start.addingTimeInterval(seconds), key: key, value: value,
                       headers: headers)
        }
        return [
            event("greetings.requested", 0, 118, 0.0, key: "1", value: #"{"id":"1","name":"Alice"}"#,
                  headers: [KafkaHeader(name: "EVENT_ID", value: "e-118"), KafkaHeader(name: "traceparent", value: "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01")]),
            event("greetings.sent", 1, 42, 0.21, key: "1", value: #"{"id":"1","message":"Hello, Alice!"}"#,
                  headers: [KafkaHeader(name: "EVENT_ID", value: "e-201")]),
            event("orders.created", 4, 9031, 1.6, key: "ORD-1042", value: #"{"order":"ORD-1042","customer":"c-77","total":129.9,"currency":"EUR","items":3}"#,
                  headers: [KafkaHeader(name: "EVENT_ID", value: "e-9031")]),
            event("greetings.requested", 2, 87, 2.4, key: "2", value: #"{"id":"2","name":""}"#,
                  headers: [KafkaHeader(name: "EVENT_ID", value: "e-119")]),
            event("greetings.requested.kafka-poc.dlq", 0, 5, 2.9, key: "2", value: #"{"id":"2","name":""}"#,
                  headers: [KafkaHeader(name: "EVENT_ID", value: "e-119"), KafkaHeader(name: "DLQ_REASON", value: "name: required"),
                            KafkaHeader(name: "DLQ_TOPIC", value: "greetings.requested")]),
            event("orders.created", 1, 7712, 3.8, key: "ORD-1043", value: #"{"order":"ORD-1043","customer":"c-12","total":42.5,"currency":"EUR","items":1}"#),
        ]
    }()
}
