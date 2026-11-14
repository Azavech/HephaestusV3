import Foundation
import ToolsFoundation

extension Ticket {
    /// Fixed tickets for the example and its previews, across the sample projects.
    static let samples: [Ticket] = [
        // Orders
        Ticket(
            id: "ORD-142", projectID: "ORD",
            title: "Retry storm between checkout and payments",
            details: """
            When payments-api answers slowly, orders-api retries without any backoff and triples the load. \
            Seen twice this week during the nightly batch.

            Add exponential backoff with jitter and cap the retries at three.
            """,
            status: .inProgress, priority: .urgent, labels: ["payments", "incident"], reporter: "You",
            createdAt: at(-2, 9), updatedAt: at(0, 8),
            links: [
                TicketLink(id: "l1", kind: .service, title: "payments-api", target: "payments-api"),
                TicketLink(id: "l2", kind: .request, title: "POST /orders/8812/checkout, 4.2 s", target: "req-8f3a"),
                TicketLink(id: "l3", kind: .build, title: "Run 1288: add backoff to the payments client", target: "1288"),
            ],
            events: [
                TicketEvent(id: 1, kind: .statusChanged, text: "You created this ticket", date: at(-2, 9)),
                TicketEvent(id: 2, kind: .commented, text: "Claude commented", date: at(-1, 7), comment: """
                    Linked a slow checkout from the nightly batch: orders-api called payments-api three times \
                    in 4.2 s, each call waiting for the full provider timeout. The three calls start within 30 ms \
                    of each other, so the retries have no delay at all.
                    """),
                TicketEvent(id: 3, kind: .commented, text: "You commented", date: at(-1, 9), comment: """
                    Backoff alone won't do: the provider timeout is 4 s and our own deadline is 5 s. \
                    Cap the retries at three and stop retrying once less than a second is left.
                    """),
                TicketEvent(id: 4, kind: .statusChanged, text: "You started work", date: at(0, 8)),
                TicketEvent(id: 5, kind: .commented, text: "You linked run 1288", date: at(0, 13)),
            ]
        ),
        Ticket(
            id: "ORD-141", projectID: "ORD",
            title: "Document cursor pagination on GET /orders",
            details: """
            GET /orders returns a cursor, but the contract and the docs still describe page numbers.

            Drafted from the difference between the contract and the deployed service.
            """,
            status: .draft, priority: .low, labels: ["docs", "contract"], reporter: "Claude",
            createdAt: at(-1, 16), updatedAt: at(-1, 16),
            links: [
                TicketLink(id: "l1", kind: .contract, title: "GET /orders", target: "listOrders"),
                TicketLink(id: "l2", kind: .service, title: "orders-api", target: "orders-api"),
            ],
            events: [TicketEvent(id: 1, kind: .drafted, text: "Claude drafted this ticket", date: at(-1, 16))]
        ),
        Ticket(
            id: "ORD-139", projectID: "ORD",
            title: "Slow query when listing a customer's orders",
            details: "The list takes almost two seconds for large customers. The query plan shows a sequential scan on orders.",
            status: .inReview, priority: .high, labels: ["database"], reporter: "You",
            createdAt: at(-4, 11), updatedAt: at(-1, 18),
            links: [
                TicketLink(id: "l1", kind: .request, title: "GET /customers/{id}/orders, 1.8 s", target: "req-41c0"),
                TicketLink(id: "l2", kind: .contract, title: "GET /customers/{id}/orders", target: "listCustomerOrders"),
            ],
            events: [
                TicketEvent(id: 1, kind: .statusChanged, text: "You created this ticket", date: at(-4, 11)),
                TicketEvent(id: 2, kind: .commented, text: "You commented", date: at(-2, 15), comment: """
                    An index on (customer_id, created_at) brings it down to 30 ms on a copy of production. \
                    The migration takes about four minutes on the largest table.
                    """),
                TicketEvent(id: 3, kind: .statusChanged, text: "You sent it to review", date: at(-1, 18)),
            ]
        ),
        Ticket(
            id: "ORD-137", projectID: "ORD",
            title: "Cancel orders that wait for payment more than an hour",
            details: "Orders stuck in awaiting_payment hold stock. Cancel them after an hour and release the stock.",
            status: .created, priority: .medium, labels: ["orders"], reporter: "You",
            createdAt: at(-6, 14), updatedAt: at(-6, 14),
            links: [TicketLink(id: "l1", kind: .service, title: "inventory-api", target: "inventory-api")],
            events: [TicketEvent(id: 1, kind: .statusChanged, text: "You created this ticket", date: at(-6, 14))]
        ),
        Ticket(
            id: "ORD-136", projectID: "ORD",
            title: "Order events queue grows during deploys",
            details: "notifications-worker stops consuming while it restarts. The backlog takes ten minutes to drain.",
            status: .draft, priority: .medium, labels: ["events"], reporter: "Claude",
            createdAt: at(-1, 10), updatedAt: at(-1, 10),
            links: [TicketLink(id: "l1", kind: .service, title: "order-events", target: "order-events")],
            events: [TicketEvent(id: 1, kind: .drafted, text: "Claude drafted this ticket", date: at(-1, 10))]
        ),
        Ticket(
            id: "ORD-130", projectID: "ORD",
            title: "Add the customer id to every log line",
            details: "Searching the logs of one customer needs the id on every line, not only on the first one.",
            status: .done, priority: .low, labels: ["observability"], reporter: "You",
            createdAt: at(-14, 9), updatedAt: at(-10, 17),
            links: [],
            events: [
                TicketEvent(id: 1, kind: .statusChanged, text: "You created this ticket", date: at(-14, 9)),
                TicketEvent(id: 2, kind: .statusChanged, text: "You marked it as done", date: at(-10, 17)),
            ]
        ),

        // Payments
        Ticket(
            id: "PAY-58", projectID: "PAY",
            title: "Charges fail when the provider times out",
            details: "A provider timeout leaves the charge pending forever. Poll the provider before giving up.",
            status: .inProgress, priority: .high, labels: ["provider"], reporter: "You",
            createdAt: at(-3, 10), updatedAt: at(0, 9),
            links: [
                TicketLink(id: "l1", kind: .service, title: "stripe", target: "stripe"),
                TicketLink(id: "l2", kind: .contract, title: "POST /charges", target: "createCharge"),
            ],
            events: [TicketEvent(id: 1, kind: .statusChanged, text: "You started work", date: at(0, 9))]
        ),
        Ticket(
            id: "PAY-57", projectID: "PAY",
            title: "Refunds of partial captures",
            details: "Refunding part of a partial capture returns 500.",
            status: .created, priority: .medium, labels: ["refunds"], reporter: "You",
            createdAt: at(-5, 15), updatedAt: at(-5, 15),
            links: [TicketLink(id: "l1", kind: .contract, title: "POST /charges/{id}/refunds", target: "refundCharge")],
            events: [TicketEvent(id: 1, kind: .statusChanged, text: "You created this ticket", date: at(-5, 15))]
        ),
        Ticket(
            id: "PAY-55", projectID: "PAY",
            title: "Fix the failing integration test of webhooks",
            details: "The last build failed in the webhook signature test.",
            status: .draft, priority: .high, labels: ["ci"], reporter: "Claude",
            createdAt: at(0, -4), updatedAt: at(0, -4),
            links: [TicketLink(id: "l1", kind: .build, title: "Run 641", target: "641")],
            events: [TicketEvent(id: 1, kind: .drafted, text: "Claude drafted this ticket", date: at(0, -4))]
        ),

        // Edge Gateway
        Ticket(
            id: "GW-21", projectID: "GW",
            title: "Trace IDs missing from gateway logs",
            details: "Requests that enter through edge-gateway lose their trace id, so the service map shows them as new traces.",
            status: .inReview, priority: .high, labels: ["observability"], reporter: "You",
            createdAt: at(-6, 14), updatedAt: at(-1, 18),
            links: [TicketLink(id: "l1", kind: .service, title: "edge-gateway", target: "edge-gateway")],
            events: [TicketEvent(id: 1, kind: .statusChanged, text: "You sent it to review", date: at(-1, 18))]
        ),

        // Tools
        Ticket(
            id: "TLS-12", projectID: "TLS",
            title: "Project switcher in every tool window",
            details: "Each tool window shows its project in the toolbar and switches it without opening another window.",
            status: .inProgress, priority: .high, labels: ["projects"], reporter: "You",
            createdAt: at(-1, 9), updatedAt: at(0, 10),
            links: [],
            events: [TicketEvent(id: 1, kind: .statusChanged, text: "You started work", date: at(0, 10))]
        ),
        Ticket(
            id: "TLS-11", projectID: "TLS",
            title: "Service map: show the path of a request",
            details: "Selecting a request highlights the services and calls it went through.",
            status: .created, priority: .medium, labels: ["service map"], reporter: "You",
            createdAt: at(-2, 11), updatedAt: at(-2, 11),
            links: [],
            events: [TicketEvent(id: 1, kind: .statusChanged, text: "You created this ticket", date: at(-2, 11))]
        ),
        Ticket(
            id: "TLS-9", projectID: "TLS",
            title: "Move the badge style into AZDesign",
            details: "Tickets, Builds and Contracts all use the capsule badge. It belongs in AZDesign.",
            status: .draft, priority: .low, labels: ["design"], reporter: "Claude",
            createdAt: at(-1, 12), updatedAt: at(-1, 12),
            links: [],
            events: [TicketEvent(id: 1, kind: .drafted, text: "Claude drafted this ticket", date: at(-1, 12))]
        ),

        // AZDesign
        Ticket(
            id: "AZD-7", projectID: "AZD",
            title: "Fira Code target for code views",
            details: "Add the Fira Code font in its own target, with ligatures on.",
            status: .created, priority: .medium, labels: ["fonts"], reporter: "You",
            createdAt: at(-3, 9), updatedAt: at(-3, 9),
            links: [],
            events: [TicketEvent(id: 1, kind: .statusChanged, text: "You created this ticket", date: at(-3, 9))]
        ),
        // Shop
        Ticket(
            id: "SHOP-14", projectID: "SHOP",
            title: "Move the shop namespace to the new staging cluster",
            details: "staging-eu is being retired. Move the namespace, its secrets and its ingress to staging-eu-2, one service at a time.",
            status: .inProgress, priority: .high, labels: ["cluster"], reporter: "You",
            createdAt: at(-3, 10), updatedAt: at(0, 4),
            links: [TicketLink(id: "l1", kind: .service, title: "edge-gateway", target: "edge-gateway")],
            events: [TicketEvent(id: 1, kind: .statusChanged, text: "You started work", date: at(0, 4))]
        ),
        Ticket(
            id: "SHOP-12", projectID: "SHOP",
            title: "One Helm chart for every service of the shop",
            details: "The three services copy the same chart. Keep one chart in the shop's repository and give each service its values.",
            status: .draft, priority: .medium, labels: ["helm"], reporter: "Claude",
            createdAt: at(-1, 15), updatedAt: at(-1, 15),
            links: [],
            events: [TicketEvent(id: 1, kind: .drafted, text: "Claude drafted this ticket", date: at(-1, 15))]
        ),
        // ToolsKit
        Ticket(
            id: "TKIT-4", projectID: "TKIT",
            title: "String catalogs for the package targets",
            details: "In a package, SwiftUI looks up string keys in the app's main bundle. Give each target its catalog and pass the bundle.",
            status: .inReview, priority: .medium, labels: ["localization"], reporter: "You",
            createdAt: at(-2, 11), updatedAt: at(0, 12),
            links: [],
            events: [TicketEvent(id: 1, kind: .statusChanged, text: "You sent it to review", date: at(0, 12))]
        ),
        Ticket(
            id: "TKIT-3", projectID: "TKIT",
            title: "Move the shared components into AZDesign",
            details: "The badge style, StatusDot and Figure are used by every tool. Move them before a second app needs them.",
            status: .created, priority: .low, labels: ["design"], reporter: "You",
            createdAt: at(-1, 9), updatedAt: at(-1, 9),
            links: [],
            events: [TicketEvent(id: 1, kind: .statusChanged, text: "You created this ticket", date: at(-1, 9))]
        ),
    ]

    /// A time on a day counted from the sample "now", 11 November 2026.
    private static func at(_ days: Int, _ hour: Int) -> Date {
        SampleClock.date(days: days, hours: hour - 14)
    }
}

extension TicketBundle {
    static let samples: [TicketBundle] = [
        TicketBundle(id: "ORD-B3", projectID: "ORD", title: "Checkout reliability", ticketIDs: ["ORD-142", "ORD-139", "ORD-137"]),
        TicketBundle(id: "ORD-B2", projectID: "ORD", title: "Contract clean-up", ticketIDs: ["ORD-141", "ORD-130"]),
        TicketBundle(id: "PAY-B1", projectID: "PAY", title: "Provider timeouts", ticketIDs: ["PAY-58", "PAY-55"]),
    ]
}
