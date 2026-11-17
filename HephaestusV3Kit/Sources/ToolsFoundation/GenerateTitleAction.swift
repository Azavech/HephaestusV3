import SwiftUI

/// Why a title couldn't be generated, in the user's words.
nonisolated public struct GenerateTitleError: Error, Sendable, Hashable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}

/// Writes a ticket's title from its description with the internal skill `set-ticket-title`
/// (docs/ui/system-prompts.md). ToolsScenes gives it to every window; **Generate Title**, in New Ticket and in the
/// ticket editor, calls it.
nonisolated public struct GenerateTitleAction: Sendable {
    /// The ticket a title is for, which the run links as a chat links an item, so that Claude can read it.
    public struct Ticket: Sendable, Hashable {
        public let id: String
        public let projectID: Project.ID

        public init(id: String, projectID: Project.ID) {
            self.id = id
            self.projectID = projectID
        }
    }

    private let generate: @MainActor @Sendable (String, Ticket?) async throws(GenerateTitleError) -> String

    public init(_ generate: @escaping @MainActor @Sendable (String, Ticket?) async throws(GenerateTitleError) -> String) {
        self.generate = generate
    }

    /// A title for `description`; `ticket` when the ticket exists (the editor's), nil before it's created (New
    /// Ticket's).
    @MainActor
    public func callAsFunction(_ description: String, ticket: Ticket? = nil) async throws(GenerateTitleError) -> String {
        try await generate(description, ticket)
    }
}

nonisolated extension EnvironmentValues {
    /// The title generator; nil in previews, where **Generate Title** doesn't show.
    @Entry public var generateTitle: GenerateTitleAction? = nil
}
