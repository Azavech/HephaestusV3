import FileStorage
import Foundation
import Testing
@testable import ProjectData

/// docs/data.md › Dashboard widget: V2's widget keys, V3's additions, and the write rules.
@Suite("Dashboard widgets")
struct DashboardWidgetEntryTests {
    private func entry(_ yaml: String) throws -> DashboardWidgetEntry {
        try YAMLCoding.decode(DashboardWidgetEntry.self, from: Data(yaml.utf8))
    }

    @Test("A key of another kind is an unknown key of the widget, kept after the widget's own keys")
    func otherKindsKeys() throws {
        let widget = try entry("id: 00000000-0000-0000-0000-000000000001\nkind: project\ncount: 3\ntitle: A\nfields:\n- name\n")
        #expect(widget.count == 5, "count belongs to other kinds")
        #expect(widget.unknownKeys.keys == ["count"])
        #expect(try YAMLCoding.encode(widget) == """
            id: 00000000-0000-0000-0000-000000000001
            kind: project
            title: A
            fields:
            - name
            count: 3

            """)
    }

    @Test("V3's Recent Builds keeps a count, and a widget without position leaves the position keys out")
    func recentBuilds() throws {
        let widget = DashboardWidgetEntry(id: DashboardWidgetEntry.defaultID(3), kind: .recentBuilds, count: 8)
        #expect(try YAMLCoding.encode(widget) == "id: 00000000-0000-0000-0000-000000000003\nkind: recentBuilds\ntitle: ''\ncount: 8\n")
        #expect(try entry(try YAMLCoding.encode(widget)) == widget)
    }

    @Test("A kind or a status neither app knows makes the widget unreadable, as in V2")
    func unknownValues() {
        #expect(throws: (any Error).self) { try entry("id: 00000000-0000-0000-0000-000000000001\nkind: weather\n") }
        #expect(throws: (any Error).self) {
            try entry("id: 00000000-0000-0000-0000-000000000001\nkind: tickets\nstatuses:\n- someday\n")
        }
    }

    @Test("Each rule of a widget the list adds or changes, with its message")
    func rules() {
        let id = UUID()
        func message(_ widget: DashboardWidgetEntry) -> String? {
            do throws(ProjectRuleError) {
                _ = try DashboardWidgetEntry.checked([widget], keeping: [])
                return nil
            } catch {
                return error.description
            }
        }
        #expect(message(DashboardWidgetEntry(id: id, kind: .project, title: String(repeating: "a", count: 101)))
            == "dashboardWidgets[0]: use a title of at most 100 characters on one line.")
        #expect(message(DashboardWidgetEntry(id: id, kind: .project, column: 0))
            == "dashboardWidgets[0]: give the column, row, width and height together.")
        #expect(message(DashboardWidgetEntry(id: id, kind: .project, column: 20, row: 0, width: 5, height: 1))
            == "dashboardWidgets[0]: use a column and a width inside the 24 columns.")
        #expect(message(DashboardWidgetEntry(id: id, kind: .project, column: 0, row: -1, width: 5, height: 1))
            == "dashboardWidgets[0]: use a row from 0 and a height of at least 1.")
        #expect(message(DashboardWidgetEntry(id: id, kind: .project, fields: [])) == "dashboardWidgets[0]: use at least one field, each once.")
        #expect(message(DashboardWidgetEntry(id: id, kind: .tickets, statuses: [.done, .done]))
            == "dashboardWidgets[0]: use at least one status, each once.")
        #expect(message(DashboardWidgetEntry(id: id, kind: .recentBuilds, count: 21)) == "dashboardWidgets[0]: use a number of rows from 1 to 20.")
        #expect(message(DashboardWidgetEntry(id: id, kind: .recentChats, chatCount: 0))
            == "dashboardWidgets[0]: use a number of chats from 1 to 20.")
        #expect(message(DashboardWidgetEntry(id: id, kind: .project, title: "  Mine  ")) == nil)
        #expect(try! DashboardWidgetEntry.checked([DashboardWidgetEntry(id: id, kind: .project, title: "  Mine  ")], keeping: [])[0].title == "Mine")
    }

    @Test("A stored widget is written back as it is, even off the rules; a copy of it and a repeated id are refused")
    func keptAndRepeated() throws {
        let odd = DashboardWidgetEntry(id: UUID(), kind: .busiestCalls, count: 50)
        #expect(try DashboardWidgetEntry.checked([odd], keeping: [odd]) == [odd])
        #expect(throws: ProjectRuleError.widget(field: "dashboardWidgets[1]", message: "use a number of rows from 1 to 20")) {
            try DashboardWidgetEntry.checked([odd, odd], keeping: [odd])
        }
        let fine = DashboardWidgetEntry(id: odd.id, kind: .project)
        #expect(throws: ProjectRuleError.duplicateWidget(odd.id.uuidString)) {
            try DashboardWidgetEntry.checked([odd, fine], keeping: [odd])
        }
    }
}
