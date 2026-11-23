import Foundation
import KafkaData
import MCPKit
import Testing
@testable import KafkaKit

/// docs/ui/kafka.md: the tool's model on the sample store; no kcat runs.
@Suite("Kafka")
@MainActor
struct KafkaModelTests {
    /// Lets the spy's updates reach the model.
    func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(150))
    }

    @Test("Every topic by default: the events arrive newest first, then stop and clear")
    func spyAll() async {
        let model = KafkaModel(projectID: "ORD", store: SampleKafkaStore())
        await model.load()
        #expect(model.environment == "Local" && model.topics.count == 4)
        #expect(model.selectionTitle == "All Topics" && model.canStart)
        model.start()
        await settle()
        #expect(model.events.count == SampleKafkaStore.sampleEvents.count)
        #expect(model.events.first?.offset == 7712)
        if case .running = model.state {} else { Issue.record("not running: \(model.state)") }
        model.stop()
        #expect(model.state == .stopped && model.events.count == 6)
        model.clear()
        #expect(model.events.isEmpty)
    }

    @Test("Chosen topics: only theirs, the title says how many")
    func chosen() async {
        let model = KafkaModel(projectID: "ORD", store: SampleKafkaStore())
        await model.load()
        model.toggle("greetings.sent")
        #expect(model.selectionTitle == "greetings.sent")
        model.toggle("orders.created")
        #expect(model.selectionTitle == "2 Topics")
        model.start()
        await settle()
        #expect(Set(model.events.map(\.topic)) == ["greetings.sent", "orders.created"])
        #expect(model.counts["orders.created"] == 2)
        model.toggle("greetings.sent")
        model.toggle("orders.created")
        #expect(!model.canStart)
    }

    @Test("The filter looks in topics, keys, values and headers")
    func filter() async {
        let model = KafkaModel(projectID: "ORD", store: SampleKafkaStore())
        model.start()
        await settle()
        model.filter = "dlq_reason"
        #expect(model.visibleEvents.map(\.topic) == ["greetings.requested.kafka-poc.dlq"])
        model.filter = "alice"
        #expect(model.visibleEvents.count == 2)
    }

    @Test("Past the limit, the oldest events go")
    func limit() {
        let model = KafkaModel(projectID: "ORD", store: SampleKafkaStore())
        for offset in 0..<(KafkaModel.maximumEvents + 10) {
            model.apply(.event(KafkaEvent(topic: "t", partition: 0, offset: Int64(offset))))
        }
        model.flush()
        #expect(model.events.count == KafkaModel.maximumEvents && model.dropped == 10)
        #expect(model.events.first?.offset == Int64(KafkaModel.maximumEvents + 9))
    }

    @Test("A project without Kafka, a failed listing, kcat's problems and a failed end")
    func states() async {
        #expect(!KafkaModel(projectID: "PAY", store: SampleKafkaStore()).hasKafka)
        let store = SampleKafkaStore()
        store.failure = KafkaError("Local: Broker transport failure")
        let model = KafkaModel(projectID: "ORD", store: store)
        await model.load()
        #expect(model.topicsState == .failed("Local: Broker transport failure"))
        model.apply(.problem("Connect to ipv4#127.0.0.1:9094 failed"))
        #expect(model.problem == "Connect to ipv4#127.0.0.1:9094 failed")
        model.apply(.ended("kcat ended: exited(1)."))
        #expect(model.state == .failed("kcat ended: exited(1)."))
    }

    @Test("Claude's tools: topics and events of the first environment with brokers")
    func tools() async throws {
        let store = SampleKafkaStore()
        let operations = KafkaTools.operations(store: store)
        #expect(operations.map(\.name) == ["list_kafka_topics", "read_kafka_events"])
        let topics = try await operations[0].run(["projectID": "ord"])
        #expect(topics["environment"] == "Local" && topics["topics"]?.arrayValue?.count == 4)
        let events = try await operations[1].run(["projectID": "ORD", "environment": "Local", "topics": ["greetings.sent"]])
        #expect(events["events"]?.arrayValue?.first?["value"] == #"{"id":"1","message":"Hello, Alice!"}"#)
        await #expect(throws: ToolError(.invalid, "environment: ORD has no environment Production with Kafka brokers.")) {
            _ = try await operations[1].run(["projectID": "ORD", "environment": "Production"])
        }
        await #expect(throws: ToolError(.notFound, "PAY has no environment with Kafka brokers: they are set in Project Settings.")) {
            _ = try await operations[0].run(["projectID": "PAY"])
        }
        store.hasKcat = false
        await #expect(throws: ToolError(.unavailable, KafkaError.noKcat.message)) { _ = try await operations[0].run(["projectID": "ORD"]) }
    }
}
