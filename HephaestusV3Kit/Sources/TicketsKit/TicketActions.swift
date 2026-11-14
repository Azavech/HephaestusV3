import SwiftUI
import ToolsFoundation

/// The toolbar's ticket actions: the status menu and the button for the next step.
///
/// They stay in the toolbar when no ticket is selected, disabled, so the toolbar never shifts. The
/// status menu's items have ⌃⌘1 to ⌃⌘5, in workflow order, and the next step has ⇧⌘↩. The actions
/// are closures the example leaves empty.
struct TicketActions: ToolbarContent {
    let ticket: Ticket?
    /// An iPhone's layout: the status as its icon alone, the next step as an icon with its name in the
    /// help tag, so the toolbar's buttons fit.
    var isCompact = false
    var onNextStep: () -> Void = {}
    var onChangeStatus: (TicketStatus) -> Void = { _ in }

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                ForEach(TicketStatus.allCases) { status in
                    Button {
                        onChangeStatus(status)
                    } label: {
                        Label(status.title, systemImage: status.symbol)
                    }
                    .keyboardShortcut(status.shortcut, modifiers: [.control, .command])
                    .disabled(status == ticket?.status)
                    .accessibilityIdentifier("ticket.status.\(status.rawValue)")
                }
            } label: {
                if isCompact {
                    Label(statusTitle, systemImage: ticket?.status.symbol ?? "circle.dashed")
                        .labelStyle(.iconOnly)
                } else {
                    Label(statusTitle, systemImage: ticket?.status.symbol ?? "circle.dashed")
                        .labelStyle(.titleAndIcon)
                        .toolbarLabelPadding()
                }
            }
            .disabled(ticket == nil)
            .help(String(localized: "Change Status", bundle: #bundle))
            .accessibilityIdentifier("ticket.status.menu")
        }

        ToolbarItem(placement: .primaryAction) {
            Button(action: onNextStep) {
                if isCompact {
                    Label(nextStepTitle, systemImage: "arrow.right")
                        .labelStyle(.iconOnly)
                } else {
                    Text(verbatim: nextStepTitle)
                        .toolbarLabelPadding()
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: [.shift, .command])
            .help(ticket?.status.nextStepHelp ?? nextStepTitle)
            .disabled(ticket?.status.nextStepTitle == nil)
            .accessibilityLabel(nextStepTitle)
            .accessibilityIdentifier("ticket.nextStep")
        }
    }

    private var statusTitle: String {
        ticket?.status.title ?? TicketWords.status
    }

    private var nextStepTitle: String {
        ticket?.status.nextStepTitle ?? String(localized: "Next Step", bundle: #bundle)
    }
}
