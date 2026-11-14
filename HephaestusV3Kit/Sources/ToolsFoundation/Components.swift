import AZDesign
import SwiftUI

// The app's own components. Generic ones (badges, status dots, figures, sections, the adaptive window
// layout, the phone stack, preview traits) come from AZDesign: see its README.

/// A project's symbol in its color.
public struct ProjectIcon: View {
    let project: Project

    public init(_ project: Project) {
        self.project = project
    }

    public var body: some View {
        Image(systemName: project.symbol)
            .foregroundStyle(project.tint.color)
            .accessibilityHidden(true)
    }
}
