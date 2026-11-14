import Foundation
import ToolsFoundation

nonisolated extension Contract {
    /// The contract of a sample project, or nil for projects without one.
    static func sample(for projectID: Project.ID) -> Contract? {
        switch projectID {
        case "ORD": orders
        case "PAY": payments
        case "GW": gateway
        default: nil
        }
    }

    private static let orders = Contract(
        title: "Orders API",
        version: "1.4.0",
        operations: [
            Operation(
                id: "listOrders", method: .get, path: "/orders", summary: "List orders", tag: "Orders",
                parameters: [
                    Parameter(name: "cursor", location: .query, type: "string", isRequired: false, example: ""),
                    Parameter(name: "limit", location: .query, type: "integer", isRequired: false, example: "20"),
                ],
                requestBody: nil,
                responses: [DocumentedResponse(status: 200, description: "A page of orders and the cursor of the next one")],
                lastResponse: SampleResponse(status: 200, duration: .milliseconds(84), bytes: 1_486, body: """
                {
                  "orders": [
                    { "id": "8813", "customerId": "c-1093", "status": "awaiting_payment", "total": 129.90 },
                    { "id": "8812", "customerId": "c-0417", "status": "paid", "total": 54.00 }
                  ],
                  "next": "b3JkZXI6ODgxMQ"
                }
                """)
            ),
            Operation(
                id: "createOrder", method: .post, path: "/orders", summary: "Create an order", tag: "Orders",
                parameters: [Parameter(name: "Idempotency-Key", location: .header, type: "string", isRequired: true, example: "7f1c2e")],
                requestBody: """
                {
                  "customerId": "c-1093",
                  "items": [ { "sku": "sku-118", "quantity": 2 } ]
                }
                """,
                responses: [
                    DocumentedResponse(status: 201, description: "The new order"),
                    DocumentedResponse(status: 409, description: "The idempotency key was used with another body"),
                ],
                lastResponse: SampleResponse(status: 201, duration: .milliseconds(230), bytes: 312, body: """
                {
                  "id": "8813",
                  "status": "awaiting_payment",
                  "total": 129.90
                }
                """)
            ),
            Operation(
                id: "getOrder", method: .get, path: "/orders/{id}", summary: "Get an order", tag: "Orders",
                parameters: [Parameter(name: "id", location: .path, type: "string", isRequired: true, example: "8812")],
                requestBody: nil,
                responses: [DocumentedResponse(status: 200, description: "The order"), DocumentedResponse(status: 404, description: "No order with this id")],
                lastResponse: SampleResponse(status: 200, duration: .milliseconds(18), bytes: 402, body: """
                {
                  "id": "8812",
                  "customerId": "c-0417",
                  "status": "paid",
                  "items": [ { "sku": "sku-9", "quantity": 1 } ],
                  "total": 54.00
                }
                """)
            ),
            Operation(
                id: "checkoutOrder", method: .post, path: "/orders/{id}/checkout", summary: "Pay for an order", tag: "Orders",
                parameters: [Parameter(name: "id", location: .path, type: "string", isRequired: true, example: "8812")],
                requestBody: """
                { "paymentMethod": "pm_card_visa" }
                """,
                responses: [
                    DocumentedResponse(status: 201, description: "The order is paid"),
                    DocumentedResponse(status: 402, description: "The payment was declined"),
                ],
                lastResponse: SampleResponse(status: 504, duration: .milliseconds(4_210), bytes: 96, body: """
                {
                  "error": "payment_timeout",
                  "message": "payments-api did not answer in time"
                }
                """)
            ),
            Operation(
                id: "cancelOrder", method: .delete, path: "/orders/{id}", summary: "Cancel an order", tag: "Orders",
                parameters: [Parameter(name: "id", location: .path, type: "string", isRequired: true, example: "8790")],
                requestBody: nil,
                responses: [DocumentedResponse(status: 204, description: "Cancelled")],
                lastResponse: SampleResponse(status: 204, duration: .milliseconds(41), bytes: 0, body: "")
            ),
            Operation(
                id: "listCustomerOrders", method: .get, path: "/customers/{id}/orders", summary: "List a customer's orders", tag: "Customers",
                parameters: [Parameter(name: "id", location: .path, type: "string", isRequired: true, example: "c-1093")],
                requestBody: nil,
                responses: [DocumentedResponse(status: 200, description: "The customer's orders, newest first")],
                lastResponse: SampleResponse(status: 200, duration: .milliseconds(1_820), bytes: 18_204, body: """
                {
                  "orders": [ { "id": "8813", "status": "awaiting_payment" } ],
                  "next": null
                }
                """)
            ),
        ]
    )

    private static let payments = Contract(
        title: "Payments API",
        version: "2.1.0",
        operations: [
            Operation(
                id: "createCharge", method: .post, path: "/charges", summary: "Charge a payment method", tag: "Charges",
                parameters: [],
                requestBody: """
                { "orderId": "8812", "amount": 5400, "currency": "eur" }
                """,
                responses: [DocumentedResponse(status: 201, description: "The charge"), DocumentedResponse(status: 402, description: "Declined")],
                lastResponse: SampleResponse(status: 201, duration: .milliseconds(520), bytes: 240, body: """
                { "id": "ch_3Qx", "status": "captured" }
                """)
            ),
            Operation(
                id: "getCharge", method: .get, path: "/charges/{id}", summary: "Get a charge", tag: "Charges",
                parameters: [Parameter(name: "id", location: .path, type: "string", isRequired: true, example: "ch_3Qx")],
                requestBody: nil,
                responses: [DocumentedResponse(status: 200, description: "The charge")],
                lastResponse: SampleResponse(status: 200, duration: .milliseconds(31), bytes: 240, body: """
                { "id": "ch_3Qx", "status": "captured" }
                """)
            ),
            Operation(
                id: "refundCharge", method: .post, path: "/charges/{id}/refunds", summary: "Refund a charge", tag: "Refunds",
                parameters: [Parameter(name: "id", location: .path, type: "string", isRequired: true, example: "ch_3Qx")],
                requestBody: """
                { "amount": 1000 }
                """,
                responses: [DocumentedResponse(status: 201, description: "The refund")],
                lastResponse: SampleResponse(status: 500, duration: .milliseconds(88), bytes: 64, body: """
                { "error": "internal", "message": "partial capture" }
                """)
            ),
            Operation(
                id: "listCharges", method: .get, path: "/charges", summary: "List charges", tag: "Charges",
                parameters: [Parameter(name: "orderId", location: .query, type: "string", isRequired: false, example: "8812")],
                requestBody: nil,
                responses: [DocumentedResponse(status: 200, description: "The charges")],
                lastResponse: SampleResponse(status: 200, duration: .milliseconds(44), bytes: 512, body: """
                { "charges": [ { "id": "ch_3Qx", "status": "captured" } ] }
                """)
            ),
        ]
    )

    private static let gateway = Contract(
        title: "Edge Gateway",
        version: "1.0.2",
        operations: [
            Operation(
                id: "health", method: .get, path: "/healthz", summary: "Health check", tag: "Operations",
                parameters: [], requestBody: nil,
                responses: [DocumentedResponse(status: 200, description: "Healthy")],
                lastResponse: SampleResponse(status: 200, duration: .milliseconds(2), bytes: 15, body: "{ \"ok\": true }")
            ),
            Operation(
                id: "listRoutes", method: .get, path: "/routes", summary: "List the routes", tag: "Routing",
                parameters: [], requestBody: nil,
                responses: [DocumentedResponse(status: 200, description: "The routes")],
                lastResponse: SampleResponse(status: 200, duration: .milliseconds(6), bytes: 820, body: """
                { "routes": [ { "prefix": "/orders", "service": "orders-api" } ] }
                """)
            ),
            Operation(
                id: "updateRoute", method: .patch, path: "/routes/{prefix}", summary: "Change where a route goes", tag: "Routing",
                parameters: [Parameter(name: "prefix", location: .path, type: "string", isRequired: true, example: "orders")],
                requestBody: """
                { "service": "orders-api", "timeoutMs": 5000 }
                """,
                responses: [DocumentedResponse(status: 200, description: "The route")],
                lastResponse: SampleResponse(status: 200, duration: .milliseconds(9), bytes: 96, body: """
                { "prefix": "/orders", "service": "orders-api", "timeoutMs": 5000 }
                """)
            ),
        ]
    )
}
