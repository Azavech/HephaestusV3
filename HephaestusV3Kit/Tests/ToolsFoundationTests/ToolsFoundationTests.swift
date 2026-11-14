import Foundation
import Testing
@testable import ToolsFoundation

@Suite("Tool layout")
struct ToolLayoutTests {
    @Test("Below 640 points a window is an iPhone", arguments: [390.0, 500, 639])
    func phone(width: Double) {
        #expect(ToolLayout.forWidth(width, macWidth: 900) == .phone)
    }

    @Test("Between the iPhone and the Mac widths a window is an iPad", arguments: [640.0, 760, 899])
    func pad(width: Double) {
        #expect(ToolLayout.forWidth(width, macWidth: 900) == .pad)
    }

    @Test("From the tool's Mac width a window is a Mac")
    func mac() {
        #expect(ToolLayout.forWidth(900, macWidth: 900) == .mac)
        #expect(ToolLayout.forWidth(2_560, macWidth: 900) == .mac)
    }

    @Test("An open chat panel needs its room on top of the tool's Mac width")
    func panel() {
        #expect(ToolLayout.forWidth(1_000, macWidth: 900, panelWidth: 341) == .pad)
        #expect(ToolLayout.forWidth(1_241, macWidth: 900, panelWidth: 341) == .mac)
    }
}

@Suite("Routes")
struct RouteTests {
    @Test("Two requests for the same item are two requests, so the second selects it again")
    func repeatedFocus() {
        let first = FocusRequest("ORD-142")
        let second = FocusRequest("ORD-142")
        #expect(first != second)
        #expect(first == first)
        #expect(second.focus == "ORD-142")
    }

    @Test("A reference opens its tool's window on its item")
    func referenceRoute() {
        let reference = ChatReference(tool: .tickets, projectID: "ORD", focus: "ORD-142", title: "ORD-142")
        #expect(reference.route == .tool(.tickets, project: "ORD", focus: "ORD-142"))
    }

    @Test("The same service in two environments is two references")
    func referenceEnvironment() {
        let production = ChatReference(
            tool: .serviceMap, projectID: "ORD", focus: "service:payments-api", title: "payments-api", environment: "Production"
        )
        let staging = ChatReference(
            tool: .serviceMap, projectID: "ORD", focus: "service:payments-api", title: "payments-api", environment: "Staging"
        )
        let unscoped = ChatReference(tool: .serviceMap, projectID: "ORD", focus: "service:payments-api", title: "payments-api")
        #expect(production.id != staging.id)
        #expect(unscoped.id == "serviceMap/ORD/service:payments-api")
    }
}

@Suite("Strings")
struct StringTests {
    @Test("Shared titles come from ToolsFoundation's catalog, in English first")
    func titles() {
        #expect(ToolKind.serviceMap.title == "Service Map")
        #expect(TicketStatus.inProgress.title == "In Progress")
        #expect(DashboardWidgetKind.requestsPerMinute.title == "Requests per Minute")
    }

    @Test("Every tool has a title, a symbol and its own shortcut")
    func tools() {
        #expect(Set(ToolKind.allCases.map(\.shortcut.character)).count == ToolKind.allCases.count)
        for tool in ToolKind.allCases {
            #expect(!tool.title.isEmpty)
            #expect(!tool.symbol.isEmpty)
        }
    }
}

@Suite("Inherited settings")
struct InheritedSettingsTests {
    @Test("A sub project that uses its parent's settings reads the parent's environments")
    func inherited() {
        let orders = Project.sample("ORD")!
        let shop = Project.sample("SHOP")!
        #expect(orders.usesParentSettings)
        #expect(orders.deploymentEnvironments.map(\.url) == shop.environments.map(\.url))
        #expect(shop.deploymentEnvironments.map(\.url) == shop.environments.map(\.url))
    }
}
