import Foundation
import ToolsFoundation

/// The Contracts tool's read function for other clients, the chat among them: what an operation is,
/// how its last call went, and what is worth asking about it. In the real suite it answers from the
/// tool's API; here, from the sample contracts.
public enum ContractsReader {
    /// `focus` is an `operationId`, e.g. `checkoutOrder`, of `project`'s contract.
    public static func read(_ focus: String, project: Project) -> ToolReading? {
        read(focus, project: project, store: SampleContractStore())
    }

    /// Reads from `store`, with the values formatted for `locale`.
    static func read(_ focus: String, project: Project, store: any ContractStore, locale: Locale = .current) -> ToolReading? {
        guard let contract = store.contract(of: project.id), let operation = contract.operation(focus) else { return nil }
        let response = operation.lastResponse
        let method = operation.method.rawValue
        let duration = response.duration.formatted(response.durationStyle.locale(locale))
        let detail = String(
            localized: "\(operation.summary): \(method) \(operation.path), in \(contract.title) \(contract.version). Its last call answered \(response.status) after \(duration).",
            bundle: #bundle,
            locale: locale,
            comment: "What an operation is, for the chat. Pay for an order: POST /orders/{id}/checkout, in Orders API 1.4.0. Its last call answered 504 after 4.2 sec."
        )
        return ToolReading(
            action: String(localized: "Read operation \(operation.id)", bundle: #bundle, locale: locale, comment: "A tool call of the chat; the value is an operationId."),
            detail: detail,
            suggestions: suggestions(for: operation, locale: locale)
        )
    }

    /// The questions worth asking about `operation`: why its last call failed, when it did, and an
    /// example request.
    static func suggestions(for operation: Operation, locale: Locale = .current) -> [String] {
        let id = operation.id
        let example = String(localized: "Show an example request for \(id)", bundle: #bundle, locale: locale)
        let status = operation.lastResponse.status
        if operation.lastResponse.isError {
            return [
                String(localized: "Why did \(id) answer \(status)?", bundle: #bundle, locale: locale, comment: "A question to the chat about an operation's last call, such as: Why did checkoutOrder answer 504?"),
                example,
            ]
        }
        return [example, String(localized: "What does \(id) return?", bundle: #bundle, locale: locale)]
    }

    static func reference(_ operation: Operation, in project: Project) -> ChatReference {
        ChatReference(tool: .contracts, projectID: project.id, focus: operation.id, title: operation.id)
    }
}
