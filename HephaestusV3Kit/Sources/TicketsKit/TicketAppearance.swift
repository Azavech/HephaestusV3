import AZDesign
import ToolsFoundation
import SwiftUI

// How tickets look: names, symbols and colors. Colors are AZDesign's semantic colors only.

/// Words the window uses as labels in more than one place: one string each for the translator.
enum TicketWords {
    /// A property, a section of the sidebar and of the Filter menu, the status menu without a ticket.
    static var status: String {
        String(localized: "Status", bundle: #bundle, comment: "The word for a ticket's status, as a label: a property, a section of the sidebar, the status menu without a ticket")
    }

    /// A property, a field of the New Ticket sheet.
    static var priority: String {
        String(localized: "Priority", bundle: #bundle, comment: "The word for a ticket's priority, as a label: a property, a field of the New Ticket sheet")
    }
}

extension TicketStatus {
    // `title` is in ToolsFoundation, with the type.

    var symbol: String {
        switch self {
        case .draft: "circle.dashed"
        case .created: "circle"
        case .inProgress: "circle.lefthalf.filled"
        case .inReview: "eye.circle"
        case .done: "checkmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .draft: .textSecondary
        case .created: .info
        case .inProgress: .accent
        case .inReview: .warning
        case .done: .success
        }
    }

    /// The key of the status menu's item, with ⌃⌘: ⌃⌘1 for Draft to ⌃⌘5 for Done, in workflow order.
    var shortcut: KeyEquivalent {
        switch self {
        case .draft: "1"
        case .created: "2"
        case .inProgress: "3"
        case .inReview: "4"
        case .done: "5"
        }
    }

    /// The name of the button that moves a ticket one step forward. `nil` once the ticket is done.
    var nextStepTitle: String? {
        switch self {
        case .draft: String(localized: "Create Ticket", bundle: #bundle)
        case .created: String(localized: "Start Work", bundle: #bundle)
        case .inProgress: String(localized: "Send to Review", bundle: #bundle)
        case .inReview: String(localized: "Mark as Done", bundle: #bundle)
        case .done: nil
        }
    }

    /// The next-step button's help tag: the step's name and its shortcut, ⇧⌘↩.
    var nextStepHelp: String? {
        switch self {
        case .draft: String(localized: "Create Ticket (⇧⌘↩)", bundle: #bundle)
        case .created: String(localized: "Start Work (⇧⌘↩)", bundle: #bundle)
        case .inProgress: String(localized: "Send to Review (⇧⌘↩)", bundle: #bundle)
        case .inReview: String(localized: "Mark as Done (⇧⌘↩)", bundle: #bundle)
        case .done: nil
        }
    }
}

extension TicketPriority {
    var title: String {
        switch self {
        case .low: String(localized: "Low", bundle: #bundle, comment: "A ticket's priority")
        case .medium: String(localized: "Medium", bundle: #bundle, comment: "A ticket's priority")
        case .high: String(localized: "High", bundle: #bundle, comment: "A ticket's priority")
        case .urgent: String(localized: "Urgent", bundle: #bundle, comment: "A ticket's priority")
        }
    }

    var symbol: String {
        switch self {
        case .low: "arrow.down"
        case .medium: "minus"
        case .high: "arrow.up"
        case .urgent: "exclamationmark.2"
        }
    }

    var color: Color {
        switch self {
        case .low: .textSecondary
        case .medium: .info
        case .high: .warning
        case .urgent: .danger
        }
    }
}

extension TicketLink.Kind {
    var title: String {
        switch self {
        case .service: String(localized: "Service", bundle: #bundle, comment: "The kind of an item a ticket links to")
        case .request: String(localized: "Request", bundle: #bundle, comment: "The kind of an item a ticket links to")
        case .contract: String(localized: "Contract", bundle: #bundle, comment: "The kind of an item a ticket links to")
        case .build: String(localized: "Build", bundle: #bundle, comment: "The kind of an item a ticket links to")
        }
    }

    var symbol: String {
        switch self {
        case .service: "shippingbox"
        case .request: "arrow.left.arrow.right"
        case .contract: "curlybraces.square"
        case .build: "hammer"
        }
    }
}

extension TicketEvent.Kind {
    var symbol: String {
        switch self {
        case .drafted: "sparkles"
        case .statusChanged: "arrow.right.circle"
        case .commented: "text.bubble"
        }
    }
}
