import Foundation
import MCPKit

/// A span of a trace, as Jaeger's v3 API gives it in OTLP JSON.
public struct TraceSpan: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case server, client, producer, consumer, other }

    public let traceID: String
    public let spanID: String
    public let parentID: String?
    public let service: String
    public let name: String
    public let kind: Kind
    public let start: Date
    public let end: Date
    public let attributes: [String: String]
    public let failed: Bool
    public let events: [Event]

    public struct Event: Sendable, Hashable {
        public let time: Date
        public let name: String
        public let attributes: [String: String]
    }

    public var durationMs: Int { max(0, Int(end.timeIntervalSince(start) * 1000)) }
    public var status: Int? { (attributes["http.response.status_code"] ?? attributes["http.status_code"]).flatMap(Int.init) }

    /// The spans of an OTLP JSON answer, `{"result": {"resourceSpans": …}}` or `{"resourceSpans": …}`.
    public static func spans(_ value: JSONValue) -> [TraceSpan] {
        let root = value["result"] ?? value
        var spans: [TraceSpan] = []
        for resource in root["resourceSpans"]?.arrayValue ?? [] {
            let service = attributes(resource["resource"]?["attributes"])["service.name"] ?? "unknown"
            for scope in resource["scopeSpans"]?.arrayValue ?? [] {
                for span in scope["spans"]?.arrayValue ?? [] {
                    guard let trace = span["traceId"]?.stringValue, let id = span["spanId"]?.stringValue,
                          let start = time(span["startTimeUnixNano"]), let end = time(span["endTimeUnixNano"]) else { continue }
                    let kind: Kind = switch span["kind"] {
                    case .int(2)?, .string("SPAN_KIND_SERVER")?: .server
                    case .int(3)?, .string("SPAN_KIND_CLIENT")?: .client
                    case .int(4)?, .string("SPAN_KIND_PRODUCER")?: .producer
                    case .int(5)?, .string("SPAN_KIND_CONSUMER")?: .consumer
                    default: .other
                    }
                    let attrs = attributes(span["attributes"])
                    let statusCode = span["status"]?["code"]
                    let failed = statusCode == .int(2) || statusCode == .string("STATUS_CODE_ERROR") || attrs["error"] == "true"
                    let parent = span["parentSpanId"]?.stringValue
                    spans.append(TraceSpan(
                        traceID: trace.lowercased(), spanID: id, parentID: (parent?.isEmpty ?? true) ? nil : parent, service: service,
                        name: span["name"]?.stringValue ?? "", kind: kind, start: start, end: end, attributes: attrs, failed: failed,
                        events: (span["events"]?.arrayValue ?? []).compactMap { event in
                            guard let at = time(event["timeUnixNano"]) else { return nil }
                            return Event(time: at, name: event["name"]?.stringValue ?? "", attributes: attributes(event["attributes"]))
                        }
                    ))
                }
            }
        }
        return spans
    }

    static func time(_ value: JSONValue?) -> Date? {
        let nanos: Double? = switch value {
        case .string(let text)?: Double(text)
        case .int(let number)?: Double(number)
        case .double(let number)?: number
        default: nil
        }
        return nanos.map { Date(timeIntervalSince1970: $0 / 1_000_000_000) }
    }

    /// OTLP attributes as text: arrays joined with `, `.
    static func attributes(_ value: JSONValue?) -> [String: String] {
        var result: [String: String] = [:]
        for entry in value?.arrayValue ?? [] {
            guard let key = entry["key"]?.stringValue, let any = entry["value"] else { continue }
            result[key] = text(any)
        }
        return result
    }

    static func text(_ any: JSONValue) -> String {
        if let string = any["stringValue"]?.stringValue { return string }
        if let value = any["intValue"] { return value.stringValue ?? value.intValue.map(String.init) ?? "" }
        if let value = any["doubleValue"]?.doubleValue { return String(value) }
        if let value = any["boolValue"]?.boolValue { return value ? "true" : "false" }
        if let values = any["arrayValue"]?["values"]?.arrayValue { return values.map(text).joined(separator: ", ") }
        return ""
    }
}

/// Jaeger's v3 query API, through a port forward (docs/data.md › Clusters › Jaeger).
public struct JaegerClient: Sendable {
    public let base: URL
    public let session: URLSession

    public init(port: Int, session: URLSession = .shared) {
        base = URL(string: "http://127.0.0.1:\(port)")!
        self.session = session
    }

    static func formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    /// The spans of the traces of `service` in the window; a full answer (10,000 traces) is read again in halves.
    public func spans(service: String, from start: Date, to end: Date) async throws(ClusterError) -> [TraceSpan] {
        let formatter = Self.formatter()
        var components = URLComponents(url: base.appendingPathComponent("api/v3/traces"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "query.service_name", value: service),
            URLQueryItem(name: "query.start_time_min", value: formatter.string(from: start)),
            URLQueryItem(name: "query.start_time_max", value: formatter.string(from: end)),
            URLQueryItem(name: "query.search_depth", value: "10000"),
        ]
        guard let value = try await get(components.url!) else { return [] }
        let spans = TraceSpan.spans(value)
        if Set(spans.map(\.traceID)).count >= 10_000, end.timeIntervalSince(start) > 1 {
            let middle = start.addingTimeInterval(end.timeIntervalSince(start) / 2)
            return try await self.spans(service: service, from: start, to: middle) + self.spans(service: service, from: middle, to: end)
        }
        return spans
    }

    /// The spans of one trace; empty when Jaeger hasn't it.
    public func trace(_ id: String) async throws(ClusterError) -> [TraceSpan] {
        guard let value = try await get(base.appendingPathComponent("api/v3/traces/\(id)")) else { return [] }
        return TraceSpan.spans(value)
    }

    /// The JSON of a GET; nil for 404.
    private func get(_ url: URL) async throws(ClusterError) -> JSONValue? {
        do {
            let (data, response) = try await session.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 404 { return nil }
            guard status == 200 else { throw ClusterError.unavailable("Jaeger answered \(status).") }
            return try JSONValue.parse(data)
        } catch let error as ClusterError {
            throw error
        } catch {
            throw .unavailable(error.localizedDescription)
        }
    }
}
