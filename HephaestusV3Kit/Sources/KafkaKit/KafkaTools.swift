import Foundation
import KafkaData
import MCPKit
import ToolsFoundation

/// The Kafka operations the MCP server offers Claude (docs/mcp.md › Kafka tools): an environment's topics, and the
/// last events of some topics or of all of them, read as the Kafka tool reads them, through kcat.
public enum KafkaTools {
    @MainActor
    public static func operations(store: any KafkaStore) -> [ToolOperation] {
        [listTopics(store), readEvents(store)]
    }

    static let projectID = ToolSchema.string("Project identifier, 2 to 8 letters, such as ORD.")
    static let environment = ToolSchema.string("The environment whose Kafka to read, as get_project names it; the project's first environment with Kafka brokers when omitted.")
    /// A value longer than this many characters is cut for Claude.
    static let valueLimit = 8_000

    /// How a chat shows a call (docs/ui/chat.md › Tool-call rows).
    static func describe(_ name: String) -> @Sendable (JSONValue) -> ToolCallText {
        { arguments in
            let project = (arguments["projectID"]?.stringValue ?? "").uppercased()
            let item = ToolItem(tool: "kafka", projectID: project, focus: "", title: project)
            return name == "list_kafka_topics"
                ? ToolCallText(action: String(localized: "Listed the Kafka topics of \(project)", bundle: #bundle), item: item)
                : ToolCallText(action: String(localized: "Read Kafka events of \(project)", bundle: #bundle), item: item)
        }
    }

    /// The environment a call names, else the project's first with brokers.
    @MainActor
    static func environment(_ arguments: JSONValue, store: any KafkaStore) throws(ToolError) -> (project: String, environment: KafkaEnvironment) {
        let project = try arguments.string("projectID").uppercased()
        let environments = store.environments(of: project)
        if let name = arguments["environment"]?.stringValue {
            guard let environment = environments.first(where: { $0.name == name }) else {
                throw ToolError(.invalid, "environment: \(project) has no environment \(name) with Kafka brokers.")
            }
            return (project, environment)
        }
        guard let first = environments.first else {
            throw ToolError(.notFound, "\(project) has no environment with Kafka brokers: they are set in Project Settings.")
        }
        return (project, first)
    }

    @MainActor
    static func ready(_ store: any KafkaStore) async throws(ToolError) {
        await store.waitForTools()
        guard store.hasKcat else { throw ToolError(.unavailable, KafkaError.noKcat.message) }
    }

    @MainActor
    static func listTopics(_ store: any KafkaStore) -> ToolOperation {
        ToolOperation(
            name: "list_kafka_topics",
            description: "Returns the Kafka topics of an environment of a project, each with its partitions, as kcat reads them from the brokers this Mac reaches. Topics whose names start with _ are Kafka's own.",
            inputSchema: .object(properties: [("projectID", projectID), ("environment", environment)], required: ["projectID"]),
            permission: .read,
            describe: describe("list_kafka_topics")
        ) { @MainActor arguments throws(ToolError) in
            let (project, environment) = try environment(arguments, store: store)
            try await ready(store)
            do throws(KafkaError) {
                let topics = try await store.topics(project: project, environment: environment.name)
                return ["environment": .string(environment.name), "brokers": .string(environment.brokers),
                        "topics": .array(topics.map { ["name": .string($0.name), "partitions": .int($0.partitions)] })]
            } catch {
                throw ToolError(.unavailable, error.message)
            }
        }
    }

    @MainActor
    static func readEvents(_ store: any KafkaStore) -> ToolOperation {
        ToolOperation(
            name: "read_kafka_events",
            description: "Returns the last events of Kafka topics of an environment of a project, oldest first: each with its topic, partition, offset, time, key, headers and value (cut after 8,000 characters). topics omitted reads every topic but Kafka's own, 50 at most. last is how many events of each partition, 10 by default; 500 events at most in all.",
            inputSchema: .object(properties: [
                ("projectID", projectID), ("environment", environment),
                ("topics", .array("The topics to read; every topic but Kafka's own when omitted.", of: .string())),
                ("last", .integer("How many of the last events of each partition, 1 to 100; 10 by default.", minimum: 1, maximum: 100)),
            ], required: ["projectID"]),
            permission: .read,
            describe: describe("read_kafka_events")
        ) { @MainActor arguments throws(ToolError) in
            let (project, environment) = try environment(arguments, store: store)
            try await ready(store)
            do throws(KafkaError) {
                var topics = (arguments["topics"]?.arrayValue ?? []).compactMap(\.stringValue)
                if topics.isEmpty {
                    topics = Array(try await store.topics(project: project, environment: environment.name)
                        .filter { !$0.isInternal }.map(\.name).prefix(Kcat.readTopicLimit))
                }
                let events = try await store.read(project: project, environment: environment.name, topics: topics,
                                                  last: arguments["last"]?.intValue ?? 10)
                return ["environment": .string(environment.name), "events": .array(events.map(json))]
            } catch {
                throw ToolError(.unavailable, error.message)
            }
        }
    }

    static func json(_ event: KafkaEvent) -> JSONValue {
        var object: [String: JSONValue] = [
            "topic": .string(event.topic), "partition": .int(event.partition), "offset": .int(Int(event.offset)),
            "key": event.key.map(JSONValue.string) ?? .null,
            "headers": .array(event.headers.map { ["name": .string($0.name), "value": $0.value.map(JSONValue.string) ?? .null] }),
        ]
        if let timestamp = event.timestamp { object["timestamp"] = .string(timestamp.formatted(.iso8601)) }
        if let value = event.value, value.count > valueLimit {
            object["value"] = .string(String(value.prefix(valueLimit)))
            object["valueCut"] = .bool(true)
        } else {
            object["value"] = event.value.map(JSONValue.string) ?? .null
        }
        return .object(object)
    }
}
