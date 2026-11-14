import AZDesign
import ToolsFoundation
import SwiftUI

/// The sheet for writing a new ticket.
///
/// The fields hold what you type in `draft` and nothing else: Cancel and Create only call their
/// closures. A parent project's window offers its sub projects in a Project field.
struct NewTicketView: View {
    @Binding var draft: NewTicketDraft
    /// The projects the ticket can go to. The Project field shows only when there is a choice.
    var projects: [Project] = []
    /// The sheet's width in an iPhone's layout, to fit the window; nil keeps the Mac's 460 to 480 pt.
    var width: CGFloat? = nil
    var onCancel: () -> Void = {}
    var onCreate: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            Text("New Ticket", bundle: #bundle)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top])
                .accessibilityAddTraits(.isHeader)

            Form {
                Section {
                    TextField(String(localized: "Title", bundle: #bundle), text: $draft.title, prompt: Text("Title", bundle: #bundle))
                        .labelsHidden()
                        .accessibilityIdentifier("newTicket.title")
                    TextField(
                        String(localized: "Description", bundle: #bundle), text: $draft.details,
                        prompt: Text("Description", bundle: #bundle), axis: .vertical
                    )
                    .lineLimit(4...8)
                    .labelsHidden()
                    .accessibilityIdentifier("newTicket.description")
                }

                Section {
                    if projects.count > 1 {
                        Picker(String(localized: "Project", bundle: #bundle), selection: $draft.projectID) {
                            ForEach(projects) { project in
                                Text(verbatim: project.name).tag(project.id)
                            }
                        }
                        .accessibilityIdentifier("newTicket.project")
                    }
                    Picker(TicketWords.priority, selection: $draft.priority) {
                        ForEach(TicketPriority.allCases) { priority in
                            Text(verbatim: priority.title).tag(priority)
                        }
                    }
                    .accessibilityIdentifier("newTicket.priority")
                    Toggle(String(localized: "Save as Draft", bundle: #bundle), isOn: $draft.startsAsDraft)
                        .accessibilityIdentifier("newTicket.draft.toggle")
                } footer: {
                    Text("A draft stays out of the workflow until you create it.", bundle: #bundle)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Divider()

            HStack {
                Spacer()
                Button(String(localized: "Cancel", bundle: #bundle), role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("newTicket.cancel")
                Button(String(localized: "Create", bundle: #bundle), action: onCreate)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.canCreate)
                    .accessibilityIdentifier("newTicket.create")
            }
            .padding()
        }
        .background(.canvas)
        .frame(
            minWidth: width ?? 460, idealWidth: width ?? 480, maxWidth: width,
            minHeight: 360, idealHeight: projects.count > 1 ? 440 : 400
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("newTicket.sheet")
    }
}

#Preview("Empty", traits: .appChrome, .sizeThatFitsLayout) {
    @Previewable @State var draft = NewTicketDraft(projectID: "ORD")
    NewTicketView(draft: $draft)
}

#Preview("Filled", traits: .appChrome, .sizeThatFitsLayout) {
    @Previewable @State var draft = NewTicketDraft(
        title: "Readiness probe flaps on search",
        details: "The search pods fail their readiness probe for a few seconds after each index refresh.",
        priority: .high,
        startsAsDraft: false,
        projectID: "ORD"
    )
    NewTicketView(draft: $draft)
}

#Preview("Filled, Dark", traits: .appChrome, .sizeThatFitsLayout) {
    @Previewable @State var draft = NewTicketDraft(
        title: "Readiness probe flaps on search",
        details: "The search pods fail their readiness probe for a few seconds after each index refresh.",
        priority: .high,
        startsAsDraft: false,
        projectID: "ORD"
    )
    NewTicketView(draft: $draft)
        .preferredColorScheme(.dark)
}

#Preview("Blank Title", traits: .appChrome, .sizeThatFitsLayout) {
    @Previewable @State var draft = NewTicketDraft(title: "   ", projectID: "ORD")
    NewTicketView(draft: $draft)
}

#Preview("Parent Project", traits: .appChrome, .sizeThatFitsLayout) {
    @Previewable @State var draft = NewTicketDraft(projectID: "SHOP")
    NewTicketView(draft: $draft, projects: Project.tree.family(of: "SHOP"))
}

#Preview("iPhone", traits: .phoneLayout, .sizeThatFitsLayout) {
    @Previewable @State var draft = NewTicketDraft(projectID: "SHOP")
    NewTicketView(draft: $draft, projects: Project.tree.family(of: "SHOP"), width: 366)
}

#Preview("Largest Text", traits: .largestText, .sizeThatFitsLayout) {
    @Previewable @State var draft = NewTicketDraft(projectID: "SHOP")
    NewTicketView(draft: $draft, projects: Project.tree.family(of: "SHOP"))
}
