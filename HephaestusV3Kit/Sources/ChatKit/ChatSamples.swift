import Foundation
import ToolsFoundation

extension ChatConversation {
    /// Conversations as if the user had had them, about the sample projects. What Claude read in them
    /// matches the other tools' samples.
    static let samples: [ChatConversation] = [checkout, releaseNotes, customerIndex, webhookSecret, shopWeek]

    // MARK: Orders

    // Seen in the Staging environment, as the Service Map showed them.
    private static let paymentsAPI = ChatReference(
        tool: .serviceMap, projectID: "ORD", focus: "service:payments-api", title: "payments-api", environment: "Staging"
    )
    private static let request8f3a = ChatReference(
        tool: .serviceMap, projectID: "ORD", focus: "request:req-8f3a", title: "req-8f3a", environment: "Staging"
    )
    private static let ord142 = ChatReference(tool: .tickets, projectID: "ORD", focus: "ORD-142", title: "ORD-142")
    private static let run1288 = ChatReference(tool: .builds, projectID: "ORD", focus: "1288", title: "Run 1288")

    private static let checkout = ChatConversation(
        id: "chat-checkout", projectID: "ORD", title: "Why does checkout time out on Staging?", origin: nil,
        createdAt: SampleClock.date(minutes: -12),
        turns: [
            ChatTurn(id: "chat-checkout.1", author: .user, date: SampleClock.date(minutes: -12), blocks: [
                ChatBlock(.text("Why does checkout time out on Staging?")),
            ]),
            ChatTurn(id: "chat-checkout.2", author: .claude, date: SampleClock.date(minutes: -11), blocks: [
                ChatBlock(.toolCall(paymentsAPI, ToolReading(
                    action: "Read service payments-api",
                    detail: "Staging · Degraded · p95 4.1 s · 6.8 % errors · 1 of 2 pods ready"
                ))),
                ChatBlock(.toolCall(request8f3a, ToolReading(
                    action: "Read request req-8f3a",
                    detail: "Staging · POST /orders/8812/checkout · 504 in 4.2 s · 6 services"
                ))),
                ChatBlock(.toolCall(ord142, ToolReading(
                    action: "Read ticket ORD-142",
                    detail: "Retry storm between checkout and payments · In Progress · Urgent"
                ))),
                ChatBlock(.toolCall(run1288, ToolReading(
                    action: "Read run 1288",
                    detail: "Add backoff to the payments client · Running · CI on fix/payments-backoff"
                ))),
                ChatBlock(.text("""
                Checkout times out because payments-api is slow on Staging, not orders-api. Stripe answers in \
                about 3.8 s there, and orders-api retries the charge three times without waiting, so req-8f3a \
                took 4.2 s and ended in a 504.

                ORD-142 already tracks this, and run 1288 adds backoff to the payments client. It's still running.
                """)),
                ChatBlock(.approval(ChatApproval.comment(
                    id: "chat-checkout.comment", on: ord142,
                    preview: "Seen again on Staging: req-8f3a retried 3 times in 4.2 s and ended in a 504. Waiting on run 1288."
                ))),
            ]),
        ]
    )

    private static let run1285 = ChatReference(tool: .builds, projectID: "ORD", focus: "1285", title: "Run 1285")

    private static let releaseNotes = ChatConversation(
        id: "chat-release-notes", projectID: "ORD", title: "Release notes for 1.4.0", origin: .builds,
        createdAt: SampleClock.date(days: -1, hours: -1),
        turns: [
            ChatTurn(id: "chat-release-notes.1", author: .user, date: SampleClock.date(days: -1, hours: -1), attachments: [run1285], blocks: [
                ChatBlock(.text("Write the release notes for 1.4.0.")),
            ]),
            ChatTurn(id: "chat-release-notes.2", author: .claude, date: SampleClock.date(days: -1, hours: -1, minutes: 1), blocks: [
                ChatBlock(.toolCall(run1285, ToolReading(
                    action: "Read run 1285", detail: "Release 1.4.0 · Passed · Release on main"
                ))),
                ChatBlock(.text("""
                Orders 1.4.0
                • Orders waiting for payment for more than an hour are cancelled.
                • GET /orders pages with a cursor instead of an offset.
                • Contract 1.4.0 adds order cancellation.
                """)),
            ]),
        ]
    )

    private static let ord139 = ChatReference(tool: .tickets, projectID: "ORD", focus: "ORD-139", title: "ORD-139")
    private static let run1286 = ChatReference(tool: .builds, projectID: "ORD", focus: "1286", title: "Run 1286")

    private static let customerIndex = ChatConversation(
        id: "chat-customer-index", projectID: "ORD", title: "Why did the customer index run fail?", origin: .tickets,
        createdAt: SampleClock.date(days: -2, hours: -3),
        turns: [
            ChatTurn(id: "chat-customer-index.1", author: .user, date: SampleClock.date(days: -2, hours: -3), attachments: [ord139], blocks: [
                ChatBlock(.text("Why did run 1286 fail?")),
            ]),
            ChatTurn(id: "chat-customer-index.2", author: .claude, date: SampleClock.date(days: -2, hours: -3, minutes: 1), blocks: [
                ChatBlock(.toolCall(ord139, ToolReading(
                    action: "Read ticket ORD-139", detail: "Slow query when listing a customer's orders · In Review · High"
                ))),
                ChatBlock(.toolCall(run1286, ToolReading(
                    action: "Read run 1286", detail: "Index orders by customer · Failed · CI on perf/customer-index"
                ))),
                ChatBlock(.text("""
                The migration test failed: the new index is created inside the transaction that also backfills \
                the orders table, and the test database times out after 120 s. Creating the index concurrently, \
                outside the transaction, keeps the backfill under a second.
                """)),
            ]),
        ]
    )

    // MARK: Payments and Shop

    private static let run641 = ChatReference(tool: .builds, projectID: "PAY", focus: "641", title: "Run 641")

    private static let webhookSecret = ChatConversation(
        id: "chat-webhook-secret", projectID: "PAY", title: "Rotate the webhook secret", origin: nil,
        createdAt: SampleClock.date(days: -1, hours: -4),
        turns: [
            ChatTurn(id: "chat-webhook-secret.1", author: .user, date: SampleClock.date(days: -1, hours: -4), blocks: [
                ChatBlock(.text("What breaks if we rotate the webhook secret today? See run 641.")),
            ]),
            ChatTurn(id: "chat-webhook-secret.2", author: .claude, date: SampleClock.date(days: -1, hours: -4, minutes: 1), blocks: [
                ChatBlock(.toolCall(run641, ToolReading(
                    action: "Read run 641", detail: "Verify webhook signatures with the new secret · Failed · CI on main"
                ))),
                ChatBlock(.text("""
                Signature checks would fail: run 641 shows the verifier still reads only the old secret. Accept \
                both secrets for a day, rotate, then drop the old one.
                """)),
            ]),
        ]
    )

    private static let shopWeek = ChatConversation(
        id: "chat-shop-week", projectID: "SHOP", title: "What changed in the shop namespace this week?", origin: .dashboard,
        createdAt: SampleClock.date(days: -3),
        turns: [
            ChatTurn(id: "chat-shop-week.1", author: .user, date: SampleClock.date(days: -3), blocks: [
                ChatBlock(.text("What changed in the shop namespace this week?")),
            ]),
            ChatTurn(id: "chat-shop-week.2", author: .claude, date: SampleClock.date(days: -3, minutes: 1), blocks: [
                ChatBlock(.text("""
                Orders 1.4.0 reached Production, payments-api has been degraded on Staging since Tuesday, and the \
                shared Helm chart moved to 3.2.
                """)),
            ]),
        ]
    )
}
