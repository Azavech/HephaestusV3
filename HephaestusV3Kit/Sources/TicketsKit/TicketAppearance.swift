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

    /// The user, as the author of a ticket or a comment.
    static var you: String {
        String(localized: "You", bundle: #bundle, comment: "The user, as the author of a ticket")
    }

    /// Claude, as the author of a ticket or a comment.
    static var claude: String {
        String(localized: "Claude", bundle: #bundle, comment: "Claude, as the author of a ticket")
    }

    /// A ticket that depends on a ticket that isn't done.
    static var blocked: String {
        String(localized: "Blocked", bundle: #bundle, comment: "A ticket that depends on a ticket that isn't done")
    }

    /// A priority that isn't set.
    static var none: String {
        String(localized: "None", bundle: #bundle, comment: "A ticket property without a value: no bundle, no priority")
    }

    // Activity sentences: one per author, so each reads naturally once translated.

    static func created(by author: TicketAuthor, asDraft: Bool) -> String {
        switch (author, asDraft) {
        case (.claude, true): String(localized: "Claude drafted this ticket", bundle: #bundle)
        case (.claude, false): String(localized: "Claude created this ticket", bundle: #bundle)
        case (_, true): String(localized: "You drafted this ticket", bundle: #bundle)
        case (_, false): String(localized: "You created this ticket", bundle: #bundle)
        }
    }

    static func moved(by author: TicketAuthor, from: String, to: String) -> String {
        author == .claude ? String(localized: "Claude moved it from \(from) to \(to)", bundle: #bundle)
            : String(localized: "You moved it from \(from) to \(to)", bundle: #bundle)
    }

    static func renamed(by author: TicketAuthor, from: String, to: String) -> String {
        switch author {
        case .claude: String(localized: "Claude renamed it from “\(from)” to “\(to)”", bundle: #bundle)
        case .automatic: String(localized: "It was named “\(to)”", bundle: #bundle, comment: "The automatic naming of a ticket")
        case .user: String(localized: "You renamed it from “\(from)” to “\(to)”", bundle: #bundle)
        }
    }

    static func linkAdded(by author: TicketAuthor, kind: TicketLink.Kind, ticket: String) -> String {
        switch (author == .claude, kind == .dependsOn) {
        case (true, true): String(localized: "Claude made it depend on \(ticket)", bundle: #bundle)
        case (true, false): String(localized: "Claude related it to \(ticket)", bundle: #bundle)
        case (false, true): String(localized: "You made it depend on \(ticket)", bundle: #bundle)
        case (false, false): String(localized: "You related it to \(ticket)", bundle: #bundle)
        }
    }

    static func linkRemoved(by author: TicketAuthor, kind: TicketLink.Kind, ticket: String) -> String {
        switch (author == .claude, kind == .dependsOn) {
        case (true, true): String(localized: "Claude removed its dependency on \(ticket)", bundle: #bundle)
        case (true, false): String(localized: "Claude removed its relation to \(ticket)", bundle: #bundle)
        case (false, true): String(localized: "You removed its dependency on \(ticket)", bundle: #bundle)
        case (false, false): String(localized: "You removed its relation to \(ticket)", bundle: #bundle)
        }
    }

    static func descriptionEdited(by author: TicketAuthor) -> String {
        author == .claude ? String(localized: "Claude edited the description", bundle: #bundle)
            : String(localized: "You edited the description", bundle: #bundle)
    }

    static func commented(by author: TicketAuthor) -> String {
        author == .claude ? String(localized: "Claude commented", bundle: #bundle) : String(localized: "You commented", bundle: #bundle)
    }
}

extension BundleStatus {
    var title: String {
        switch self {
        case .todo: String(localized: "To Do", bundle: #bundle, comment: "A bundle's status")
        case .inProgress: String(localized: "In Progress", bundle: #bundle, comment: "A bundle's status")
        case .done: String(localized: "Done", bundle: #bundle, comment: "A bundle's status")
        }
    }

    var symbol: String {
        switch self {
        case .todo: "circle"
        case .inProgress: "circle.lefthalf.filled"
        case .done: "checkmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .todo: .textSecondary
        case .inProgress: .accent
        case .done: .success
        }
    }
}

extension TicketLinkDraft.Kind {
    var title: String {
        switch self {
        case .dependsOn: String(localized: "Depends On", bundle: #bundle, comment: "The kind of a link between tickets")
        case .related: String(localized: "Related", bundle: #bundle, comment: "The kind of a link between tickets")
        }
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

    /// The status the next step moves a ticket to. `nil` once the ticket is done.
    var next: TicketStatus? {
        switch self {
        case .draft: .created
        case .created: .inProgress
        case .inProgress: .inReview
        case .inReview: .done
        case .done: nil
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
        case .dependsOn: String(localized: "Depends On", bundle: #bundle, comment: "The kind of a link between tickets")
        case .blocks: String(localized: "Blocks", bundle: #bundle, comment: "The kind of a link between tickets: the other ticket depends on this one")
        case .related: String(localized: "Related", bundle: #bundle, comment: "The kind of a link between tickets")
        case .service: String(localized: "Service", bundle: #bundle, comment: "The kind of an item a ticket links to")
        case .request: String(localized: "Request", bundle: #bundle, comment: "The kind of an item a ticket links to")
        case .contract: String(localized: "Contract", bundle: #bundle, comment: "The kind of an item a ticket links to")
        case .build: String(localized: "Build", bundle: #bundle, comment: "The kind of an item a ticket links to")
        }
    }

    var symbol: String {
        switch self {
        case .dependsOn: "arrow.turn.down.right"
        case .blocks: "hand.raised"
        case .related: "link"
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
        case .created: "plus.circle"
        case .statusChanged: "arrow.right.circle"
        case .renamed: "character.cursor.ibeam"
        case .linkAdded: "link"
        case .linkRemoved: "minus.circle"
        case .descriptionEdited: "pencil"
        case .commented: "text.bubble"
        }
    }
}
