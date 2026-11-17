import SwiftUI

/// Why a title couldn't be generated, in the user's words.
nonisolated public struct GenerateTitleError: Error, Sendable, Hashable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}

/// Writes a ticket's title from its description with the internal skill `set-ticket-title`
/// (docs/ui/system-prompts.md). ToolsScenes gives it to every window; New Ticket's **Generate Title** calls it.
nonisolated public struct GenerateTitleAction: Sendable {
    private let generate: @MainActor @Sendable (String) async throws(GenerateTitleError) -> String

    public init(_ generate: @escaping @MainActor @Sendable (String) async throws(GenerateTitleError) -> String) {
        self.generate = generate
    }

    /// A title for `description`.
    @MainActor
    public func callAsFunction(_ description: String) async throws(GenerateTitleError) -> String {
        try await generate(description)
    }
}

nonisolated extension EnvironmentValues {
    /// The title generator; nil in previews, where **Generate Title** doesn't show.
    @Entry public var generateTitle: GenerateTitleAction? = nil
}
