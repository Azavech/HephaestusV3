import Foundation
import ToolsFoundation

/// Questions to start a chat from, which the empty states offer as buttons that send them.
enum ChatSuggestion {
    /// About the project as a whole, when the chat has no item to ask about.
    static var project: [String] {
        [
            String(localized: "What changed this week?", bundle: #bundle),
            String(localized: "What needs my attention?", bundle: #bundle),
        ]
    }

    /// About `item`: the questions its tool proposes for the item in its current state ("Why did run
    /// 1288 fail?" only for a run that failed), or, when the tool proposes none, questions that suit
    /// any item of its kind.
    static func about(_ item: ChatReference, reader: ToolReader) -> [String] {
        let proposed = reader(item)?.suggestions ?? []
        return proposed.isEmpty ? general(about: item) : proposed
    }

    /// Questions that suit any item of the kind, whatever its state.
    static func general(about item: ChatReference) -> [String] {
        let title = item.title
        switch item.tool {
        case .tickets:
            return [
                String(localized: "What's left before \(title) can be closed?", bundle: #bundle),
                String(localized: "Summarize \(title)", bundle: #bundle, comment: "A suggestion; the value is a ticket id, such as ORD-142"),
            ]
        case .serviceMap where item.focus.hasPrefix("request:"):
            return [
                String(localized: "Which services did \(title) go through?", bundle: #bundle, comment: "A suggestion; the value is a request id, such as req-8f3a"),
                String(localized: "Where did \(title) spend its time?", bundle: #bundle, comment: "A suggestion; the value is a request id, such as req-8f3a"),
            ]
        case .serviceMap:
            return [
                String(localized: "What calls \(title)?", bundle: #bundle, comment: "A suggestion; the value is a service, such as payments-api"),
                String(localized: "What does \(title) depend on?", bundle: #bundle, comment: "A suggestion; the value is a service, such as payments-api"),
            ]
        case .builds where item.focus.hasPrefix("release:"):
            // The release's tag, which the sentence names as a release: "What changed in release v1.4.0?".
            let tag = String(item.focus.dropFirst("release:".count))
            return [
                String(localized: "What changed in release \(tag)?", bundle: #bundle),
                String(localized: "Summarize release \(tag)", bundle: #bundle),
            ]
        case .builds:
            // The run's number, which the sentence names as a run: "What changed in run 1288?".
            let number = item.focus
            return [
                String(localized: "What changed in run \(number)?", bundle: #bundle),
                String(localized: "Summarize run \(number)", bundle: #bundle),
            ]
        case .contracts:
            return [String(localized: "Show an example request for \(title)", bundle: #bundle, comment: "A suggestion; the value is an API operation, such as createOrder")]
        case .kafka:
            // An event, `<topic>/<partition>/<offset>`, or a topic.
            return [
                String(localized: "What does \(title) say?", bundle: #bundle, comment: "A suggestion; the value is a Kafka event or topic, such as greetings.sent/1/42"),
                String(localized: "Which service publishes \(title)?", bundle: #bundle, comment: "A suggestion; the value is a Kafka event or topic, such as greetings.sent/1/42"),
            ]
        case .dashboard, .chat:
            return project
        }
    }

    /// `chat.suggestion.whats-left-before-ord-142-can-be-closed`: qualified by the question itself, so
    /// that each suggestion has its own identifier.
    nonisolated static func identifier(for suggestion: String) -> String {
        let words = suggestion.lowercased()
            .filter { $0 != "'" && $0 != "’" }
            .split { !$0.isLetter && !$0.isNumber }
        return "chat.suggestion." + words.joined(separator: "-")
    }
}
