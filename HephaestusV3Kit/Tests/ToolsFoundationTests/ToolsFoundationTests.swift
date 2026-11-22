import AppKit
import Foundation
import SwiftUI
import Testing
@testable import ToolsFoundation

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

    @Test("A request is acted on once, by whichever view takes it first, its copies included")
    @MainActor func focusTakenOnce() {
        let request = FocusRequest("ORD-142")
        let copy = request
        #expect(request.take() == "ORD-142")
        #expect(copy.take() == nil)
        #expect(FocusRequest("ORD-142").take() == "ORD-142")
    }

    @Test("A tab drawn with a request already in its environment selects the item, once (HEPH-14)")
    @MainActor func focusOnFirstDraw() async throws {
        final class Selections { var focuses: [String] = [] }
        let selections = Selections()
        let request = FocusRequest("ORD-142")
        func draw() async throws {
            let view = Color.clear.frame(width: 20, height: 20)
                .onFocusRequest { selections.focuses.append($0) }
                .environment(\.focusRequest, request)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 20, height: 20), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: view)
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            window.contentView = nil
            window.close()
        }
        try await draw()
        #expect(selections.focuses == ["ORD-142"])
        try await draw()
        #expect(selections.focuses == ["ORD-142"], "The tab drawn again doesn't select the item twice")
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
    @Test("A sub project reads its parent's environments, marked as inherited")
    func inherited() {
        let orders = Project.sample("ORD")!
        let shop = Project.sample("SHOP")!
        #expect(orders.deploymentEnvironments.map(\.url) == shop.environments.map(\.url))
        #expect(orders.deploymentEnvironments.allSatisfy { $0.inheritedFrom == "SHOP" })
        #expect(shop.deploymentEnvironments.map(\.url) == shop.environments.map(\.url))
    }
}

@Suite("Projects' environments")
struct ProjectEnvironmentTests {
    @Test("A project of the app's data named as a sample keeps its own environments, never the sample's")
    func resolvedSampleID() throws {
        let own = DeploymentEnvironment(name: "Mine", cluster: nil, namespace: nil, url: nil, health: nil)
        let project = Project(id: "SHOP", name: "My Shop", kind: .app, tint: .accent, symbol: "cart", path: "/tmp/shop", repository: "",
                              environments: [own], activity: nil, environmentsAreResolved: true)
        #expect(project.deploymentEnvironments.map(\.name) == ["Mine"])
        let sample = try #require(Project.sample("ORD"))
        #expect(!sample.deploymentEnvironments.isEmpty, "A sample still reads the sample tree")
    }
}
