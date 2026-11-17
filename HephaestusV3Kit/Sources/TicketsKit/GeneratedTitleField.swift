import AZDesign
import SwiftUI
import ToolsFoundation

/// A ticket's Title field with **Generate Title** at its end, then the reason under it when no title could be
/// written: New Ticket's and the editor's (docs/ui/tickets.md › Generate Title). The field is the caller's, in
/// its own style. Without a generator in the environment, as in previews that give none, only the field shows.
///
/// Its body is two views, the field's row and the reason, so that a form shows them as two rows and a stack as
/// two of its items.
struct GeneratedTitleField<Field: View>: View {
    @Binding var title: String
    /// What the title is written from: Generate Title is disabled while it holds only spaces and line breaks.
    let description: String
    /// The ticket, which the run links; nil before it's created.
    var ticket: GenerateTitleAction.Ticket? = nil
    /// The identifiers' start: the button is `<identifier>.generateTitle`, the reason
    /// `<identifier>.generateTitle.message`.
    let identifier: String
    @ViewBuilder let field: Field

    /// Writes the title from the description with `set-ticket-title`.
    @Environment(\.generateTitle) private var generateTitle
    @State private var generating = false
    /// Why the last generation failed.
    @State private var message: String?

    var body: some View {
        HStack(spacing: 8) {
            field
            if let generateTitle {
                if generating {
                    ProgressView().controlSize(.small)
                }
                Button {
                    generate(with: generateTitle)
                } label: {
                    Label(String(localized: "Generate Title", bundle: #bundle), systemImage: "wand.and.stars")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(generating || description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help(String(localized: "Generate a Title from the Description", bundle: #bundle))
                .accessibilityIdentifier("\(identifier).generateTitle")
            }
        }
        if let message {
            Text(verbatim: message)
                .font(.callout)
                .foregroundStyle(.danger)
                .accessibilityIdentifier("\(identifier).generateTitle.message")
        }
    }

    /// Replaces the title with the one `set-ticket-title` writes from the description.
    private func generate(with action: GenerateTitleAction) {
        let description = description
        let ticket = ticket
        generating = true
        message = nil
        Task {
            defer { generating = false }
            do throws(GenerateTitleError) {
                title = try await action(description, ticket: ticket)
            } catch {
                message = error.message
            }
        }
    }
}

#Preview("Generator", traits: .appChrome, .sizeThatFitsLayout) {
    @Previewable @State var title = ""
    VStack(alignment: .leading, spacing: 12) {
        GeneratedTitleField(title: $title, description: "The search pods fail their readiness probe after each index refresh.",
                            identifier: "preview") {
            TextField(text: $title) { Text(verbatim: "Title") }
        }
    }
    .padding()
    .frame(width: 420)
    .environment(\.generateTitle, GenerateTitleAction { _, _ in "Readiness probe flaps after index refreshes" })
}

#Preview("Failure", traits: .appChrome, .sizeThatFitsLayout) {
    @Previewable @State var title = ""
    VStack(alignment: .leading, spacing: 12) {
        GeneratedTitleField(title: $title, description: "The search pods fail their readiness probe after each index refresh.",
                            identifier: "preview") {
            TextField(text: $title) { Text(verbatim: "Title") }
        }
    }
    .padding()
    .frame(width: 420)
    .environment(\.generateTitle, GenerateTitleAction { _, _ throws(GenerateTitleError) in
        throw GenerateTitleError("Claude didn't answer within 2 minutes.")
    })
}

#Preview("Empty Description", traits: .appChrome, .sizeThatFitsLayout) {
    @Previewable @State var title = ""
    VStack(alignment: .leading, spacing: 12) {
        GeneratedTitleField(title: $title, description: "  ", identifier: "preview") {
            TextField(text: $title) { Text(verbatim: "Title") }
        }
    }
    .padding()
    .frame(width: 420)
    .environment(\.generateTitle, GenerateTitleAction { _, _ in "Never asked" })
}
