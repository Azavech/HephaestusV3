import FileStorage
import Foundation
import Testing
@testable import ProjectData

/// docs/data.md › Kafka: an environment's Kafka keys and this Mac's passwords.
@Suite("Kafka settings")
struct KafkaSettingsTests {
    @Test("An environment's Kafka keys round-trip, and a file without them gains none")
    func keys() throws {
        let entry = EnvironmentEntry(name: "local", kafkaBrokers: "localhost:9094, other:9095", kafkaUsername: "hephaestus", kafkaTLS: true)
        let yaml = try YAMLCoding.encode(entry)
        #expect(yaml.contains("kafkaBrokers: localhost:9094, other:9095\nkafkaUsername: hephaestus\nkafkaTLS: true\n"))
        let read = try YAMLCoding.decode(EnvironmentEntry.self, from: yaml)
        #expect(read == entry && read.kafkaBrokerList == ["localhost:9094", "other:9095"])
        #expect(!(try YAMLCoding.encode(EnvironmentEntry(name: "plain"))).contains("kafka"))
        let change = EnvironmentOverride(kafkaBrokers: "x:1", kafkaTLS: false)
        #expect(!change.isEmpty)
        #expect(change.applied(to: entry).kafkaBrokers == "x:1" && change.applied(to: entry).kafkaTLS == false)
        #expect(change.applied(to: entry).kafkaUsername == "hephaestus")
    }

    @Test("Brokers are host:port separated by commas")
    func rule() throws {
        #expect(ProjectRules.isKafkaBrokerList("localhost:9094"))
        #expect(ProjectRules.isKafkaBrokerList("a:9092, b.example.com:9093"))
        #expect(!ProjectRules.isKafkaBrokerList("localhost"))
        #expect(!ProjectRules.isKafkaBrokerList("a:9092,,b:1"))
        #expect(!ProjectRules.isKafkaBrokerList("a:0"))
        #expect(!ProjectRules.isKafkaBrokerList("a b:9092"))
        #expect(throws: ProjectRuleError.kafkaBrokers(field: "f")) { try ProjectRules.kafkaBrokers("nope", field: "f") }
        #expect(try ProjectRules.kafkaBrokers("  ", field: "f") == nil)
    }

    @Test("Passwords live in secrets.json, mode 0600, by project and environment, the other keys kept")
    func passwords() throws {
        try withTemporaryFolder { root in
            let folder = DataFolder(url: root.appendingPathComponent("Data"))
            try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
            let token = try folder.externalToken { String(repeating: "a", count: 64) }
            try folder.setKafkaPassword("s3cret", project: "ORD", environment: "Local")
            #expect(folder.kafkaPassword(project: "ORD", environment: "Local") == "s3cret")
            #expect(folder.kafkaPassword(project: "ORD", environment: "Staging") == nil)
            #expect(try folder.externalToken { "" } == token)
            let mode = try FileManager.default.attributesOfItem(atPath: folder.secretsFile.path)[.posixPermissions] as? Int
            #expect(mode == 0o600)
            try folder.setKafkaPassword("", project: "ORD", environment: "Local")
            #expect(folder.kafkaPassword(project: "ORD", environment: "Local") == nil)
            #expect(!(try String(contentsOf: folder.secretsFile, encoding: .utf8)).contains("kafkaPasswords"))
        }
    }
}
