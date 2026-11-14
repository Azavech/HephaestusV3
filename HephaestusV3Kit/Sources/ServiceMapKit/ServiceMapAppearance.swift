import AZDesign
import SwiftUI
import ToolsFoundation

// Names, symbols, colors and number formats of the service map. Colors are AZDesign's semantic colors
// only; text comes from the target's String Catalog or from Foundation's formatters.

extension ServiceNode.Kind {
    var title: String {
        switch self {
        case .gateway: String(localized: "Gateway", bundle: #bundle, comment: "A kind of node on the service map")
        case .service: String(localized: "Service", bundle: #bundle, comment: "A kind of node on the service map")
        case .worker: String(localized: "Worker", bundle: #bundle, comment: "A kind of node on the service map")
        case .database: String(localized: "Database", bundle: #bundle, comment: "A kind of node on the service map")
        case .queue: String(localized: "Queue", bundle: #bundle, comment: "A kind of node on the service map")
        case .external: String(localized: "External", bundle: #bundle, comment: "A kind of node on the service map: a service outside the cluster")
        case .client: String(localized: "Client", bundle: #bundle, comment: "A kind of node on the service map: who sent a request")
        }
    }

    /// The icons of the kinds (`cpu`, `cylinder.split.1x2`, Kafka's envelope, `person`).
    var symbol: String {
        switch self {
        case .gateway: "network"
        case .service: "cpu"
        case .worker: "gearshape.2"
        case .database: "cylinder.split.1x2"
        case .queue: "envelope.arrow.triangle.branch"
        case .external: "globe"
        case .client: "person"
        }
    }
}

extension ServiceCall {
    /// Red past 5 % of errors, orange past 1 %, quiet otherwise.
    var color: Color {
        if errorRate >= 0.05 { return .danger }
        if errorRate >= 0.01 { return .warning }
        return .textSecondary
    }
}

/// The color of an HTTP status: danger from 500, warning from 400, success below.
func statusColor(_ status: Int) -> Color {
    switch status {
    case 500...: .danger
    case 400..<500: .warning
    default: .success
    }
}

extension ServiceRequest {
    var statusColor: Color { ServiceMapKit.statusColor(status) }
}

extension LogLine.Level {
    var title: String {
        switch self {
        case .info: String(localized: "Info", bundle: #bundle, comment: "The level of a log line")
        case .warning: String(localized: "Warning", bundle: #bundle, comment: "The level of a log line")
        case .error: String(localized: "Error", bundle: #bundle, comment: "The level of a log line")
        }
    }

    var color: Color {
        switch self {
        case .info: .info
        case .warning: .warning
        case .error: .danger
        }
    }
}

/// How the map writes its numbers. Units come from Foundation's formatters, or sit inside one
/// localized string with their number.
enum ServiceMapFormat {
    /// Calls or requests per second, with at most one decimal: `142/s`.
    static func rate(_ perSecond: Double) -> String {
        String(localized: "\(perSecond, format: .number.precision(.fractionLength(0...1)))/s", bundle: #bundle, comment: "Calls or requests per second, short: on an arrow of the graph and in the details")
    }

    /// The same in words, for VoiceOver: `142 calls per second`.
    static func spokenRate(_ perSecond: Double) -> String {
        let tenths = (perSecond * 10).rounded() / 10
        if tenths == tenths.rounded() {
            return String(AttributedString(localized: "^[\(Int(tenths)) call](inflect: true) per second", bundle: #bundle, comment: "Calls per second, read by VoiceOver").characters)
        }
        return String(localized: "\(tenths, format: .number.precision(.fractionLength(1))) calls per second", bundle: #bundle, comment: "Calls per second with a decimal, read by VoiceOver")
    }

    /// A number of calls, short: `756K`.
    static func compactCount(_ count: Int) -> String {
        count.formatted(.number.notation(.compactName))
    }

    /// A number of calls in words, for VoiceOver: `756,000 calls`.
    static func spokenCalls(_ count: Int) -> String {
        String(AttributedString(localized: "^[\(count) call](inflect: true)", bundle: #bundle, comment: "A number of calls, read by VoiceOver").characters)
    }

    /// A duration in milliseconds: milliseconds below one second (`84 ms`), then seconds with one
    /// decimal (`4.2 sec` in English). `width` is `.wide` for VoiceOver: `4.2 seconds`.
    static func duration(_ milliseconds: Int, width: Measurement<UnitDuration>.FormatStyle.UnitWidth = .abbreviated) -> String {
        if milliseconds >= 1_000 {
            Measurement(value: Double(milliseconds) / 1_000, unit: UnitDuration.seconds)
                .formatted(.measurement(width: width, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(1))))
        } else {
            Measurement(value: Double(milliseconds), unit: UnitDuration.milliseconds)
                .formatted(.measurement(width: width, usage: .asProvided))
        }
    }

    /// A share with one decimal: `6.8%`.
    static func percent(_ share: Double) -> String {
        share.formatted(.percent.precision(.fractionLength(1)))
    }

    /// `text` as it is, inside a string with automatic grammar agreement: `AttributedString(localized:)`
    /// reads Markdown in its values too, so a path's `*` or `_` would turn into emphasis. Each ASCII
    /// punctuation mark is escaped.
    static func literal(_ text: String) -> String {
        var escaped = ""
        for character in text {
            if markdownPunctuation.contains(character) {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return escaped
    }

    private static let markdownPunctuation = Set("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")

    /// `POST /orders/8812/checkout · 504`: the route of a request, written under the Client.
    static func route(of request: ServiceRequest) -> String {
        String(localized: "\(request.method) \(request.path) · \(String(request.status))", bundle: #bundle, comment: "The route of a request under the Client node of the graph: method, path and HTTP status")
    }
}

/// Requests per second, rounded the way the map shows them.
func rateText(_ requestsPerSecond: Double) -> Text {
    Text(verbatim: ServiceMapFormat.rate(requestsPerSecond))
        .monospacedDigit()
}

/// A duration in milliseconds, written in seconds from one second up.
func durationText(_ milliseconds: Int) -> Text {
    Text(verbatim: ServiceMapFormat.duration(milliseconds))
        .monospacedDigit()
}
