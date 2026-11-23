import ExternalTools
import Foundation
import Testing
@testable import KafkaData

/// A fake kcat in a temporary folder: it records its arguments and its properties file, and answers as kcat does.
/// No test reaches a broker.
final class FakeKcat {
    let folder: URL
    let path: String

    init(script body: String) throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("KafkaDataTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        path = folder.appendingPathComponent("kcat").path
        let script = """
            #!/bin/sh
            printf '%s\\n' "$@" > "\(folder.path)/arguments"
            config="$2"
            cp "$config" "\(folder.path)/properties"
            \(body)
            """
        FileManager.default.createFile(atPath: path, contents: Data(script.utf8), attributes: [.posixPermissions: 0o755])
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    var kcat: Kcat {
        Kcat(path: path, environment: ["PATH": "/usr/bin:/bin"], runner: SystemProcessRunner(), folder: folder.appendingPathComponent("Runtime"))
    }

    var arguments: [String] {
        ((try? String(contentsOf: folder.appendingPathComponent("arguments"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    var properties: String { (try? String(contentsOf: folder.appendingPathComponent("properties"), encoding: .utf8)) ?? "" }

    /// The properties files left behind.
    var leftovers: [String] { (try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("Runtime").path)) ?? [] }
}

@Suite("Kafka through kcat")
struct KafkaDataTests {
    static let event = #"{"topic":"greetings.sent","partition":1,"offset":42,"tstype":"create","ts":1793455380123,"broker":0,"headers":["EVENT_ID","e-1","trace",null],"key":"1","payload":"{\"id\":\"1\",\"message\":\"Hello, Alice!\"}"}"#

    @Test("The properties of each listener: plain, SASL, TLS")
    func properties() {
        #expect(KafkaConnection(brokers: ["localhost:9094"]).properties == "bootstrap.servers=localhost:9094\nsecurity.protocol=PLAINTEXT\n")
        let sasl = KafkaConnection(brokers: ["a:9092", "b:9092"], username: "hephaestus", password: "p", tls: true).properties
        #expect(sasl == "bootstrap.servers=a:9092,b:9092\nsecurity.protocol=SASL_SSL\nsasl.mechanisms=SCRAM-SHA-512\nsasl.username=hephaestus\nsasl.password=p\nssl.ca.location=probe\n")
        #expect(KafkaConnection(brokers: ["a:9093"], tls: true).properties.contains("security.protocol=SSL\n"))
    }

    @Test("An event line: its place, time, key, value and headers in order")
    func event() throws {
        let event = try #require(Kcat.parseEvent(Substring(Self.event)))
        #expect(event.topic == "greetings.sent" && event.partition == 1 && event.offset == 42)
        #expect(event.timestamp == Date(timeIntervalSince1970: 1_793_455_380.123))
        #expect(event.key == "1" && event.value == #"{"id":"1","message":"Hello, Alice!"}"#)
        #expect(event.headers == [KafkaHeader(name: "EVENT_ID", value: "e-1"), KafkaHeader(name: "trace", value: nil)])
        #expect(Kcat.parseEvent("% Reached end of topic") == nil)
        #expect(Kcat.message(Data("% ERROR: Local: Broker transport failure\n".utf8)) == "Local: Broker transport failure")
    }

    @Test("Topics from the metadata, sorted, Kafka's own marked")
    func topics() async throws {
        let fake = try FakeKcat(script: #"echo '{"topics":[{"topic":"orders","partitions":[{},{},{}]},{"topic":"__consumer_offsets","partitions":[{}]}]}'"#)
        let topics = try await fake.kcat.topics(KafkaConnection(brokers: ["localhost:9094"], username: "u", password: "secret"))
        #expect(topics == [KafkaTopic(name: "__consumer_offsets", partitions: 1), KafkaTopic(name: "orders", partitions: 3)])
        #expect(topics.first?.isInternal == true)
        #expect(Array(fake.arguments.dropFirst(2)) == ["-L", "-J", "-m", "15"])
        // The password goes in the file, never in the arguments, and the file goes after the run.
        #expect(fake.properties.contains("sasl.password=secret") && !fake.arguments.contains { $0.contains("secret") })
        #expect(fake.leftovers.isEmpty)
    }

    @Test("A failed run says kcat's error")
    func failure() async throws {
        let fake = try FakeKcat(script: #"echo '% ERROR: Failed to acquire metadata: Local: Broker transport failure' >&2; exit 1"#)
        await #expect(throws: KafkaError("Failed to acquire metadata: Local: Broker transport failure")) {
            _ = try await fake.kcat.topics(KafkaConnection(brokers: ["localhost:9094"]))
        }
    }

    @Test("A read: the last events of each topic, oldest first")
    func read() async throws {
        let fake = try FakeKcat(script: "echo '\(Self.event)'")
        let events = try await fake.kcat.read(KafkaConnection(brokers: ["localhost:9094"]), topics: ["greetings.sent"], last: 5)
        #expect(events.map(\.offset) == [42])
        #expect(Array(fake.arguments.dropFirst(2)) == ["-C", "-J", "-e", "-q", "-o", "-5", "-t", "greetings.sent"])
    }

    @Test("A spy on every topic: a group of its own, from now, its events, then its end when stopped")
    func spy() async throws {
        let fake = try FakeKcat(script: "echo '\(Self.event)'; echo '% ERROR: Local: Broker transport failure' >&2; exec sleep 30")
        let spy = try fake.kcat.spy(KafkaConnection(brokers: ["localhost:9094"]), selection: .all, fromBeginning: false)
        var updates: [KafkaSpy.Update] = []
        for await update in spy.updates {
            updates.append(update)
            if updates.count == 2 { spy.stop() }
            if case .ended = update { break }
        }
        #expect(updates.contains { if case .event(let event) = $0 { event.offset == 42 } else { false } })
        #expect(updates.contains(.problem("Local: Broker transport failure")))
        #expect(updates.last == .ended(nil))
        let arguments = fake.arguments
        #expect(arguments[2] == "-G" && arguments[3].hasPrefix("hephaestus-spy-"))
        #expect(Array(arguments.dropFirst(4)) == ["-J", "-u", "-q", "-X", "enable.auto.commit=false", "-X", "auto.offset.reset=latest", "^[^_].*"])
        #expect(fake.leftovers.isEmpty)
        #expect(KafkaSpy.runningCount == 0)
    }
}
