import Foundation
import ToolsFoundation

extension ServiceMap {
    /// The `shop` namespace, as the given environment would show it.
    ///
    /// Staging has a slow payment provider, so payments-api is degraded and checkouts time out there.
    static func sample(environment: String) -> ServiceMap {
        let scale: Double = switch environment {
        case "Production": 3.2
        case "Local": 0.05
        default: 1
        }
        let staging = environment == "Staging"

        func node(
            _ id: String, _ kind: ServiceNode.Kind,
            rps: Double, p95: Int, errors: Double = 0.001, pods: Int = 3, ready: Int? = nil,
            health: DeploymentEnvironment.Health = .healthy
        ) -> ServiceNode {
            ServiceNode(
                id: id, kind: kind,
                requestsPerSecond: rps * scale, p95: p95, errorRate: errors,
                readyPods: ready ?? pods, pods: pods, health: health,
                throughput: wave(rps * scale, seed: id.count)
            )
        }

        let nodes = [
            node("edge-gateway", .gateway, rps: 238, p95: 120),
            node("orders-api", .service, rps: 142, p95: staging ? 2_400 : 95, errors: staging ? 0.031 : 0.002),
            node("inventory-api", .service, rps: 96, p95: 24),
            node("payments-api", .service, rps: 38, p95: staging ? 4_100 : 180,
                 errors: staging ? 0.068 : 0.004, pods: 2, ready: staging ? 1 : 2, health: staging ? .degraded : .healthy),
            node("orders-db", .database, rps: 330, p95: 6, pods: 1),
            node("order-events", .queue, rps: 41, p95: 3, pods: 1),
            node("payments-db", .database, rps: 44, p95: 5, pods: 1),
            node("stripe", .external, rps: 37, p95: staging ? 3_800 : 160,
                 errors: staging ? 0.041 : 0.001, pods: 0, health: staging ? .degraded : .healthy),
            node("notifications-worker", .worker, rps: 39, p95: 40, pods: 2),
        ]

        let production = environment == "Production"
        // Production runs the whole shop, not only the orders path: enough services to see the graph crowd,
        // with teams whose services never call the others standing apart.
        let shop = production ? [
            node("auth-api", .service, rps: 410, p95: 18),
            node("users-api", .service, rps: 120, p95: 22),
            node("users-db", .database, rps: 520, p95: 4, pods: 1),
            node("sessions-cache", .database, rps: 900, p95: 1, pods: 3),
            node("catalog-api", .service, rps: 380, p95: 35),
            node("catalog-db", .database, rps: 260, p95: 7, pods: 1),
            node("search-api", .service, rps: 210, p95: 140, errors: 0.012, health: .degraded),
            node("search-index", .database, rps: 210, p95: 90, pods: 3),
            node("cart-api", .service, rps: 160, p95: 30),
            node("cart-cache", .database, rps: 480, p95: 1, pods: 2),
            node("pricing-api", .service, rps: 300, p95: 12),
            node("pricing-db", .database, rps: 150, p95: 3, pods: 1),
            node("shipping-api", .service, rps: 45, p95: 220),
            node("shipping-db", .database, rps: 60, p95: 5, pods: 1),
            node("carriers", .external, rps: 30, p95: 600, pods: 0),
            node("recommendations-api", .service, rps: 140, p95: 80),
            node("mail-provider", .external, rps: 25, p95: 300, pods: 0),
            node("sms-provider", .external, rps: 6, p95: 250, pods: 0),
            node("reports-worker", .worker, rps: 4, p95: 9_000, pods: 1),
            node("exports-worker", .worker, rps: 2, p95: 4_000, pods: 1),
            node("warehouse-db", .database, rps: 8, p95: 1_200, pods: 1),
            node("reports-bucket", .external, rps: 3, p95: 90, pods: 0),
            node("audit-worker", .worker, rps: 60, p95: 6, pods: 2),
            node("audit-events", .queue, rps: 60, p95: 2, pods: 1),
            node("audit-db", .database, rps: 60, p95: 3, pods: 1),
            node("feature-flags", .service, rps: 700, p95: 2),
            node("flags-db", .database, rps: 5, p95: 2, pods: 1),
            node("cleanup-cron", .worker, rps: 0, p95: 0, pods: 1),
        ] : []

        let shopCalls = production ? [
            ServiceCall(from: "edge-gateway", to: "auth-api", requestsPerSecond: 410, errorRate: 0.001),
            ServiceCall(from: "edge-gateway", to: "users-api", requestsPerSecond: 120, errorRate: 0),
            ServiceCall(from: "edge-gateway", to: "catalog-api", requestsPerSecond: 380, errorRate: 0),
            ServiceCall(from: "edge-gateway", to: "search-api", requestsPerSecond: 210, errorRate: 0.012),
            ServiceCall(from: "edge-gateway", to: "cart-api", requestsPerSecond: 160, errorRate: 0),
            ServiceCall(from: "edge-gateway", to: "recommendations-api", requestsPerSecond: 140, errorRate: 0),
            ServiceCall(from: "auth-api", to: "sessions-cache", requestsPerSecond: 900, errorRate: 0),
            ServiceCall(from: "auth-api", to: "users-db", requestsPerSecond: 300, errorRate: 0),
            ServiceCall(from: "users-api", to: "users-db", requestsPerSecond: 220, errorRate: 0),
            ServiceCall(from: "catalog-api", to: "catalog-db", requestsPerSecond: 260, errorRate: 0),
            ServiceCall(from: "catalog-api", to: "pricing-api", requestsPerSecond: 190, errorRate: 0),
            ServiceCall(from: "search-api", to: "search-index", requestsPerSecond: 210, errorRate: 0.012),
            ServiceCall(from: "search-api", to: "catalog-api", requestsPerSecond: 40, errorRate: 0),
            ServiceCall(from: "cart-api", to: "cart-cache", requestsPerSecond: 480, errorRate: 0),
            ServiceCall(from: "cart-api", to: "pricing-api", requestsPerSecond: 110, errorRate: 0),
            ServiceCall(from: "cart-api", to: "inventory-api", requestsPerSecond: 90, errorRate: 0),
            ServiceCall(from: "pricing-api", to: "pricing-db", requestsPerSecond: 150, errorRate: 0),
            ServiceCall(from: "orders-api", to: "pricing-api", requestsPerSecond: 60, errorRate: 0),
            ServiceCall(from: "orders-api", to: "shipping-api", requestsPerSecond: 45, errorRate: 0.002),
            ServiceCall(from: "orders-api", to: "users-api", requestsPerSecond: 50, errorRate: 0),
            ServiceCall(from: "shipping-api", to: "shipping-db", requestsPerSecond: 60, errorRate: 0),
            ServiceCall(from: "shipping-api", to: "carriers", requestsPerSecond: 30, errorRate: 0.008),
            ServiceCall(from: "recommendations-api", to: "catalog-api", requestsPerSecond: 140, errorRate: 0),
            ServiceCall(from: "notifications-worker", to: "mail-provider", requestsPerSecond: 25, errorRate: 0.001),
            ServiceCall(from: "notifications-worker", to: "sms-provider", requestsPerSecond: 6, errorRate: 0),
            ServiceCall(from: "notifications-worker", to: "users-api", requestsPerSecond: 39, errorRate: 0),
            ServiceCall(from: "reports-worker", to: "warehouse-db", requestsPerSecond: 6, errorRate: 0),
            ServiceCall(from: "reports-worker", to: "reports-bucket", requestsPerSecond: 3, errorRate: 0),
            ServiceCall(from: "exports-worker", to: "warehouse-db", requestsPerSecond: 2, errorRate: 0),
            ServiceCall(from: "exports-worker", to: "reports-bucket", requestsPerSecond: 1, errorRate: 0),
            ServiceCall(from: "audit-worker", to: "audit-events", requestsPerSecond: 60, errorRate: 0),
            ServiceCall(from: "audit-worker", to: "audit-db", requestsPerSecond: 60, errorRate: 0),
            ServiceCall(from: "feature-flags", to: "flags-db", requestsPerSecond: 5, errorRate: 0),
        ] : []

        let calls = [
            ServiceCall(from: "edge-gateway", to: "orders-api", requestsPerSecond: 142 * scale, errorRate: staging ? 0.031 : 0.002),
            ServiceCall(from: "edge-gateway", to: "inventory-api", requestsPerSecond: 96 * scale, errorRate: 0.001),
            ServiceCall(from: "orders-api", to: "payments-api", requestsPerSecond: 38 * scale, errorRate: staging ? 0.068 : 0.004),
            ServiceCall(from: "orders-api", to: "orders-db", requestsPerSecond: 210 * scale, errorRate: 0),
            ServiceCall(from: "orders-api", to: "order-events", requestsPerSecond: 41 * scale, errorRate: 0),
            ServiceCall(from: "inventory-api", to: "orders-db", requestsPerSecond: 120 * scale, errorRate: 0),
            ServiceCall(from: "payments-api", to: "payments-db", requestsPerSecond: 44 * scale, errorRate: 0),
            ServiceCall(from: "payments-api", to: "stripe", requestsPerSecond: 37 * scale, errorRate: staging ? 0.041 : 0.001),
            ServiceCall(from: "order-events", to: "notifications-worker", requestsPerSecond: 39 * scale, errorRate: 0.012),
        ]

        let requests = [
            ServiceRequest(
                id: "req-8f3a", method: "POST", path: "/orders/8812/checkout", status: staging ? 504 : 201,
                duration: staging ? 4_210 : 640, startedAt: SampleClock.date(minutes: -2),
                spans: staging ? [
                    Span(id: 1, service: "edge-gateway", operation: "POST /orders/{id}/checkout", start: 0, duration: 4_210, isError: true),
                    Span(id: 2, service: "orders-api", operation: "checkout", start: 8, duration: 4_196, isError: true),
                    Span(id: 3, service: "orders-db", operation: "SELECT orders", start: 14, duration: 6, isError: false),
                    Span(id: 4, service: "payments-api", operation: "POST /charges", start: 26, duration: 4_170, isError: true),
                    Span(id: 5, service: "stripe", operation: "create charge", start: 34, duration: 4_150, isError: true),
                ] : [
                    Span(id: 1, service: "edge-gateway", operation: "POST /orders/{id}/checkout", start: 0, duration: 640, isError: false),
                    Span(id: 2, service: "orders-api", operation: "checkout", start: 8, duration: 626, isError: false),
                    Span(id: 3, service: "orders-db", operation: "SELECT orders", start: 14, duration: 6, isError: false),
                    Span(id: 4, service: "payments-api", operation: "POST /charges", start: 26, duration: 520, isError: false),
                    Span(id: 5, service: "stripe", operation: "create charge", start: 34, duration: 480, isError: false),
                    Span(id: 6, service: "order-events", operation: "publish order.paid", start: 560, duration: 4, isError: false),
                ]
            ),
            ServiceRequest(
                id: "req-41c0", method: "GET", path: "/customers/c-1093/orders", status: 200, duration: 1_820,
                startedAt: SampleClock.date(minutes: -3),
                spans: [
                    Span(id: 1, service: "edge-gateway", operation: "GET /customers/{id}/orders", start: 0, duration: 1_820, isError: false),
                    Span(id: 2, service: "orders-api", operation: "listCustomerOrders", start: 6, duration: 1_808, isError: false),
                    Span(id: 3, service: "orders-db", operation: "SELECT orders WHERE customer_id", start: 12, duration: 1_770, isError: false),
                ]
            ),
            ServiceRequest(
                id: "req-77d1", method: "GET", path: "/orders?limit=20", status: 200, duration: 84,
                startedAt: SampleClock.date(minutes: -1),
                spans: [
                    Span(id: 1, service: "edge-gateway", operation: "GET /orders", start: 0, duration: 84, isError: false),
                    Span(id: 2, service: "orders-api", operation: "listOrders", start: 5, duration: 76, isError: false),
                    Span(id: 3, service: "orders-db", operation: "SELECT orders", start: 9, duration: 41, isError: false),
                ]
            ),
            ServiceRequest(
                id: "req-0b9e", method: "GET", path: "/products/sku-118/stock", status: 200, duration: 22,
                startedAt: SampleClock.date(minutes: -1),
                spans: [
                    Span(id: 1, service: "edge-gateway", operation: "GET /products/{sku}/stock", start: 0, duration: 22, isError: false),
                    Span(id: 2, service: "inventory-api", operation: "getStock", start: 3, duration: 17, isError: false),
                    Span(id: 3, service: "orders-db", operation: "SELECT stock", start: 6, duration: 9, isError: false),
                ]
            ),
            ServiceRequest(
                id: "req-c5aa", method: "POST", path: "/orders", status: 201, duration: 230,
                startedAt: SampleClock.date(minutes: -4),
                spans: [
                    Span(id: 1, service: "edge-gateway", operation: "POST /orders", start: 0, duration: 230, isError: false),
                    Span(id: 2, service: "orders-api", operation: "createOrder", start: 6, duration: 218, isError: false),
                    Span(id: 3, service: "orders-db", operation: "INSERT orders", start: 20, duration: 12, isError: false),
                    Span(id: 4, service: "order-events", operation: "publish order.created", start: 40, duration: 3, isError: false),
                ]
            ),
            ServiceRequest(
                id: "req-19f2", method: "DELETE", path: "/orders/8790", status: 204, duration: 41,
                startedAt: SampleClock.date(minutes: -6),
                spans: [
                    Span(id: 1, service: "edge-gateway", operation: "DELETE /orders/{id}", start: 0, duration: 41, isError: false),
                    Span(id: 2, service: "orders-api", operation: "cancelOrder", start: 4, duration: 34, isError: false),
                    Span(id: 3, service: "orders-db", operation: "UPDATE orders", start: 9, duration: 8, isError: false),
                ]
            ),
            ServiceRequest(
                id: "req-a604", method: "GET", path: "/products/sku-9/stock", status: 404, duration: 12,
                startedAt: SampleClock.date(minutes: -7),
                spans: [
                    Span(id: 1, service: "edge-gateway", operation: "GET /products/{sku}/stock", start: 0, duration: 12, isError: false),
                    Span(id: 2, service: "inventory-api", operation: "getStock", start: 3, duration: 7, isError: false),
                ]
            ),
        ] + routineRequests()

        let logs = [
            LogLine(id: 1, date: SampleClock.date(minutes: -2), service: "payments-api", level: staging ? .error : .info,
                    message: staging ? "charge 8812: provider timeout after 4s, giving up" : "charge 8812: captured",
                    requestID: "req-8f3a"),
            LogLine(id: 2, date: SampleClock.date(minutes: -2), service: "orders-api", level: staging ? .warning : .info,
                    message: staging ? "checkout 8812: payments-api answered 504, retry 3 of 3" : "checkout 8812: paid",
                    requestID: "req-8f3a"),
            LogLine(id: 3, date: SampleClock.date(minutes: -2), service: "edge-gateway", level: .info,
                    message: "POST /orders/8812/checkout \(staging ? 504 : 201) in \(staging ? 4_210 : 640) ms", requestID: "req-8f3a"),
            LogLine(id: 4, date: SampleClock.date(minutes: -3), service: "orders-api", level: .warning,
                    message: "listCustomerOrders c-1093: slow query, 1770 ms", requestID: "req-41c0"),
            LogLine(id: 5, date: SampleClock.date(minutes: -3), service: "orders-db", level: .info,
                    message: "seq scan on orders (rows=1204331)", requestID: "req-41c0"),
            LogLine(id: 6, date: SampleClock.date(minutes: -4), service: "order-events", level: .info,
                    message: "order.created 8813 published", requestID: "req-c5aa"),
            LogLine(id: 7, date: SampleClock.date(minutes: -5), service: "notifications-worker", level: .warning,
                    message: "consumer lag 1.2 s on order-events", requestID: nil),
            LogLine(id: 8, date: SampleClock.date(minutes: -7), service: "inventory-api", level: .info,
                    message: "stock sku-9: not found", requestID: "req-a604"),
            LogLine(id: 9, date: SampleClock.date(minutes: -9), service: "payments-api", level: .info,
                    message: "pool: 2 of 2 pods \(staging ? "with 1 not ready" : "ready")", requestID: nil),
        ]

        return ServiceMap(nodes: nodes + shop, calls: calls + shopCalls, requests: requests, logs: logs)
    }

    /// The service of each sample project, selected when its map opens.
    static func ownService(of projectID: Project.ID) -> ServiceNode.ID? {
        switch projectID {
        case "ORD": "orders-api"
        case "PAY": "payments-api"
        case "GW": "edge-gateway"
        default: nil
        }
    }

    /// Ordinary traffic of the last half hour, under the requests the samples are about.
    private static func routineRequests() -> [ServiceRequest] {
        (0..<24).map { index in
            let minutesAgo = 8 + index
            let started = SampleClock.date(minutes: -minutesAgo)
            let id = String(format: "req-%04x", (index * 7_919 + 4_099) % 0xFFFF)
            switch index % 4 {
            case 0:
                let duration = 30 + (index * 13) % 60
                return ServiceRequest(
                    id: id, method: "GET", path: "/orders/\(8_700 + index * 3)", status: 200, duration: duration, startedAt: started,
                    spans: [
                        Span(id: 1, service: "edge-gateway", operation: "GET /orders/{id}", start: 0, duration: duration, isError: false),
                        Span(id: 2, service: "orders-api", operation: "getOrder", start: 4, duration: duration - 8, isError: false),
                        Span(id: 3, service: "orders-db", operation: "SELECT orders", start: 8, duration: 5, isError: false),
                    ]
                )
            case 1:
                let duration = 14 + (index * 7) % 20
                return ServiceRequest(
                    id: id, method: "GET", path: "/products/sku-\(100 + index * 11)/stock", status: 200, duration: duration, startedAt: started,
                    spans: [
                        Span(id: 1, service: "edge-gateway", operation: "GET /products/{sku}/stock", start: 0, duration: duration, isError: false),
                        Span(id: 2, service: "inventory-api", operation: "getStock", start: 3, duration: duration - 5, isError: false),
                        Span(id: 3, service: "orders-db", operation: "SELECT stock", start: 6, duration: 6, isError: false),
                    ]
                )
            case 2:
                let duration = 180 + (index * 17) % 90
                return ServiceRequest(
                    id: id, method: "POST", path: "/orders", status: 201, duration: duration, startedAt: started,
                    spans: [
                        Span(id: 1, service: "edge-gateway", operation: "POST /orders", start: 0, duration: duration, isError: false),
                        Span(id: 2, service: "orders-api", operation: "createOrder", start: 6, duration: duration - 12, isError: false),
                        Span(id: 3, service: "orders-db", operation: "INSERT orders", start: 20, duration: 12, isError: false),
                        Span(id: 4, service: "order-events", operation: "publish order.created", start: 40, duration: 3, isError: false),
                    ]
                )
            default:
                let duration = 60 + (index * 29) % 140
                return ServiceRequest(
                    id: id, method: "GET", path: "/orders?limit=20&cursor=c\(index * 31)", status: 200, duration: duration, startedAt: started,
                    spans: [
                        Span(id: 1, service: "edge-gateway", operation: "GET /orders", start: 0, duration: duration, isError: false),
                        Span(id: 2, service: "orders-api", operation: "listOrders", start: 5, duration: duration - 8, isError: false),
                        Span(id: 3, service: "orders-db", operation: "SELECT orders", start: 9, duration: duration / 2, isError: false),
                    ]
                )
            }
        }
    }

    /// A gentle wave around `level`, 30 values, so the sparklines differ from service to service.
    private static func wave(_ level: Double, seed: Int) -> [Double] {
        (0..<30).map { minute in
            let phase = Double(minute + seed) / 4
            return max(0, level * (1 + 0.18 * sin(phase) + 0.07 * cos(phase * 2.3)))
        }
    }
}
