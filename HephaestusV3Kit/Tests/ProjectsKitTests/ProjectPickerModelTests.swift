import Testing
@testable import ProjectsKit
import ToolsFoundation

@Suite("Project picker: the switcher and the menu bar panel")
struct ProjectPickerModelTests {
    @Test("A new list highlights its first row, or the project asked for")
    func initialHighlight() {
        #expect(ProjectPickerModel(store: MockProjectStore()).highlighted == "A")
        #expect(ProjectPickerModel(store: MockProjectStore(), highlighting: "BK").highlighted == "BK")
    }

    @Test("Each change of the filter highlights the first match")
    func filterHighlightsFirstMatch() {
        let model = ProjectPickerModel(store: MockProjectStore())
        model.query = "kit"
        #expect(model.highlighted == "BK")
        model.query = "beta"
        #expect(model.highlighted == "B")
        #expect(model.entries.map(\.depth) == [0, 0])
    }

    @Test("No match: nothing is highlighted and Return has nothing to pick")
    func noMatches() {
        let model = ProjectPickerModel(store: MockProjectStore())
        model.query = "xyz"
        #expect(model.hasNoMatches)
        #expect(model.highlighted == nil)
        #expect(model.highlightedProject == nil)
        model.move(by: 1)
        #expect(model.highlighted == nil)
    }

    @Test("↓ and ↑ move one row in list order and stop at the ends")
    func move() {
        let model = ProjectPickerModel(store: MockProjectStore())
        model.move(by: -1)
        #expect(model.highlighted == "A")
        model.move(by: 1)
        model.move(by: 1)
        #expect(model.highlighted == "A1L")
        model.highlight("C")
        model.move(by: 1)
        #expect(model.highlighted == "C")
        model.move(by: -1)
        #expect(model.highlighted == "BK")
    }

    @Test("In the switcher, projects without the window's tool are skipped and can't be highlighted")
    func requiredTool() {
        let model = ProjectPickerModel(store: MockProjectStore(), requiredTool: .contracts, highlighting: "B")
        #expect(model.highlighted == "A")
        #expect(model.isAvailable(MockProjectStore().projects[1]))
        #expect(!model.isAvailable(MockProjectStore().projects[3]))
        model.move(by: 1)
        #expect(model.highlighted == "A1")
        model.move(by: 1)
        #expect(model.highlighted == "A1")
        model.highlight("C")
        #expect(model.highlighted == "A1")
        model.query = "lib"
        #expect(model.highlighted == nil)
        #expect(model.highlightedProject == nil)
        #expect(!model.hasNoMatches)
    }

    @Test("Opening again starts afresh: no filter, the highlight on the project asked for")
    func reset() {
        let model = ProjectPickerModel(store: MockProjectStore())
        model.query = "core"
        #expect(model.highlighted == "C")
        model.reset(highlighting: "B")
        #expect(model.query.isEmpty)
        #expect(model.highlighted == "B")
        model.query = "core"
        model.reset()
        #expect(model.highlighted == "A")
    }

    @Test("Return picks the highlighted project")
    func highlightedProject() {
        let model = ProjectPickerModel(store: MockProjectStore())
        model.query = "two"
        #expect(model.highlightedProject?.id == "A2")
    }
}
