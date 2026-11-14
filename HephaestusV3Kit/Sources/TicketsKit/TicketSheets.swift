import AZDesign
import SwiftUI
import ToolsFoundation

/// Add Link: the kind of link, and the ticket of the project it points to.
struct AddLinkSheet: View {
    let ticket: Ticket
    let candidates: [Ticket]
    let onCancel: () -> Void
    let onAdd: (TicketLinkDraft) -> Void

    @State private var kind = TicketLinkDraft.Kind.dependsOn
    @State private var target: Ticket.ID?

    var body: some View {
        VStack(spacing: 0) {
            Text("Link \(ticket.id) to Another Ticket", bundle: #bundle)
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top])
                .accessibilityAddTraits(.isHeader)
            Picker(String(localized: "Kind", bundle: #bundle, comment: "The kind of a link between tickets"), selection: $kind) {
                ForEach(TicketLinkDraft.Kind.allCases) { kind in
                    Text(verbatim: kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .padding()
            .accessibilityIdentifier("addLink.kind")
            List(candidates, selection: $target) { candidate in
                HStack {
                    Text(verbatim: candidate.id)
                        .monospacedDigit()
                        .foregroundStyle(.textSecondary)
                    Text(verbatim: candidate.title)
                        .lineLimit(1)
                    Spacer()
                    Label(candidate.status.title, systemImage: candidate.status.symbol)
                        .labelStyle(.badge(candidate.status.color))
                }
                .tag(candidate.id)
                .accessibilityIdentifier("addLink.ticket.\(candidate.id)")
            }
            .scrollContentBackground(.hidden)
            .frame(minHeight: 200)
            Divider()
            HStack {
                Spacer()
                Button(String(localized: "Cancel", bundle: #bundle), role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Add Link", bundle: #bundle)) {
                    if let target { onAdd(TicketLinkDraft(kind: kind, ticketID: target)) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(target == nil)
                .accessibilityIdentifier("addLink.add")
            }
            .padding()
        }
        .background(.canvas)
        .frame(minWidth: 420, idealWidth: 480, minHeight: 360, idealHeight: 440)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("addLink.sheet")
    }
}

/// New Bundle, or a bundle's title and tickets: the project's tickets, checked in the bundle's order.
struct BundleSheet: View {
    @Binding var draft: BundleDraft
    let candidates: [Ticket]
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if draft.bundleID == nil {
                    Text("New Bundle", bundle: #bundle)
                } else {
                    Text("Edit Bundle", bundle: #bundle)
                }
            }
            .font(.title3.weight(.semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding([.horizontal, .top])
            .accessibilityAddTraits(.isHeader)
            TextField(String(localized: "Title", bundle: #bundle), text: $draft.title,
                      prompt: Text("Named after its tickets", bundle: #bundle))
                .textFieldStyle(.roundedBorder)
                .padding()
                .accessibilityIdentifier("bundle.title")
            List(candidates) { candidate in
                Toggle(isOn: Binding {
                    draft.ticketIDs.contains(candidate.id)
                } set: { isOn in
                    if isOn { draft.ticketIDs.append(candidate.id) } else { draft.ticketIDs.removeAll { $0 == candidate.id } }
                }) {
                    HStack {
                        Text(verbatim: candidate.id)
                            .monospacedDigit()
                            .foregroundStyle(.textSecondary)
                        Text(verbatim: candidate.title)
                            .lineLimit(1)
                    }
                }
                .accessibilityIdentifier("bundle.ticket.\(candidate.id)")
            }
            .scrollContentBackground(.hidden)
            .frame(minHeight: 220)
            Text("^[\(draft.ticketIDs.count) ticket](inflect: true), in the order checked.", bundle: #bundle)
                .font(.callout)
                .foregroundStyle(.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.top, 8)
            Divider()
                .padding(.top, 8)
            HStack {
                Spacer()
                Button(String(localized: "Cancel", bundle: #bundle), role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(draft.bundleID == nil ? String(localized: "Create", bundle: #bundle) : String(localized: "Save", bundle: #bundle),
                       action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.bundleID == nil && draft.ticketIDs.isEmpty)
                    .accessibilityIdentifier("bundle.save")
            }
            .padding()
        }
        .background(.canvas)
        .frame(minWidth: 420, idealWidth: 480, minHeight: 420, idealHeight: 520)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bundle.sheet")
    }
}

#Preview("Add Link", traits: .appChrome, .sizeThatFitsLayout) {
    AddLinkSheet(ticket: Ticket.samples[0], candidates: Array(Ticket.samples.filter { $0.projectID == "ORD" }.dropFirst()), onCancel: {}, onAdd: { _ in })
}

#Preview("New Bundle", traits: .appChrome, .sizeThatFitsLayout) {
    @Previewable @State var draft = BundleDraft(bundleID: nil, projectID: "ORD", title: "", ticketIDs: ["ORD-139"])
    BundleSheet(draft: $draft, candidates: Ticket.samples.filter { $0.projectID == "ORD" }, onCancel: {}, onSave: {})
}

#Preview("Edit Bundle, Dark", traits: .appChrome, .sizeThatFitsLayout) {
    @Previewable @State var draft = BundleDraft(bundleID: "ORD-B3", projectID: "ORD", title: "Checkout reliability", ticketIDs: ["ORD-142", "ORD-139", "ORD-137"])
    BundleSheet(draft: $draft, candidates: Ticket.samples.filter { $0.projectID == "ORD" }, onCancel: {}, onSave: {})
        .preferredColorScheme(.dark)
}
