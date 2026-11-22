import AppKit
import SwiftUI
import Testing
import ToolsFoundation
@testable import ProjectsKit

/// The Projects tab drawn once the projects are loaded: its selection is checked as a change of the list does.
@MainActor
@Suite("Projects selection on appearing")
struct ProjectsSelectionViewTests {
    @Test("A stored selection no longer listed, or none, gives way to the first project when the tab appears")
    func staleSelection() async throws {
        let projects = MockProjectStore().projects
        for stored in ["NOPE", nil] as [Project.ID?] {
            final class Selection { var id: Project.ID? }
            let selection = Selection()
            selection.id = stored
            let binding = Binding { selection.id } set: { selection.id = $0 }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 680), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ProjectsRootView(projects: projects, selection: binding))
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(300))
            #expect(selection.id == "A", "From \(stored ?? "nil")")
            window.contentView = nil
            window.close()
        }
    }
}
