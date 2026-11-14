import AZDesign
import SwiftUI

// Components every tool uses. They are candidates for AZDesign: they move there before a
// second app needs them (workspace rule), not before.

/// A small capsule with a colored icon, for a status, a priority or an HTTP method.
///
/// The color sits on the icon and the capsule; the text keeps the text color so it stays readable.
/// On a selected row, the color gives way to the system's own styles.
public struct BadgeLabelStyle: LabelStyle {
    let color: Color

    public func makeBody(configuration: Configuration) -> some View {
        Badge(configuration: configuration, color: color)
    }

    private struct Badge: View {
        let configuration: LabelStyleConfiguration
        let color: Color

        @Environment(\.backgroundProminence) private var backgroundProminence

        var body: some View {
            HStack(spacing: 4) {
                configuration.icon
                    .foreground(color, onSelection: .primary)
                configuration.title
                    .foreground(.textPrimary, onSelection: .primary)
            }
            .font(.caption)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(capsuleFill, in: Capsule())
        }

        private var capsuleFill: AnyShapeStyle {
            backgroundProminence == .increased
                ? AnyShapeStyle(HierarchicalShapeStyle.quaternary)
                : AnyShapeStyle(color.opacity(0.16))
        }
    }
}

extension LabelStyle where Self == BadgeLabelStyle {
    /// A capsule badge tinted with `color`.
    public static func badge(_ color: Color) -> BadgeLabelStyle {
        BadgeLabelStyle(color: color)
    }
}

extension View {
    /// Draws the view in `color`, except on a selected row, where the system's own style keeps the contrast.
    public func foreground(_ color: Color, onSelection systemStyle: HierarchicalShapeStyle) -> some View {
        modifier(SelectionAwareForeground(color: color, systemStyle: systemStyle))
    }
}

private struct SelectionAwareForeground: ViewModifier {
    let color: Color
    let systemStyle: HierarchicalShapeStyle

    @Environment(\.backgroundProminence) private var backgroundProminence

    func body(content: Content) -> some View {
        content.foregroundStyle(
            backgroundProminence == .increased ? AnyShapeStyle(systemStyle) : AnyShapeStyle(color)
        )
    }
}

extension View {
    /// Room on both sides of a toolbar control's text. In a toolbar capsule, the system leaves text
    /// about 6 points from the rounded ends, which reads as cramped next to its segmented controls.
    public func toolbarLabelPadding() -> some View {
        padding(.horizontal, 6)
    }
}

/// A colored dot for a state, beside a name.
public struct StatusDot: View {
    let color: Color

    @ScaledMetric private var size = 8.0

    public init(_ color: Color) {
        self.color = color
    }

    public var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

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

/// A figure with its caption under it, for the summaries at the top of a window.
public struct Figure: View {
    let value: Text
    let caption: Text

    public init(_ value: Text, caption: Text) {
        self.value = value
        self.caption = caption
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            value
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.textPrimary)
            caption
                .font(.caption)
                .foregroundStyle(.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// What every preview shares with the running app: the accent tint.
public struct AppChrome: PreviewModifier {
    public init() {}

    public func body(content: Content, context: Void) -> some View {
        content.tint(.accent)
    }
}

extension PreviewTrait where T == Preview.ViewTraits {
    /// Gives a preview the same tint as the app.
    public static var appChrome: Self { .modifier(AppChrome()) }
}

/// Lays a preview out as a tool window does in `layout`. Give it a size that matches:
/// `#Preview("iPhone", traits: .phoneLayout, .fixedLayout(width: 420, height: 800))`.
public struct ToolLayoutPreview: PreviewModifier {
    let layout: ToolLayout

    public init(_ layout: ToolLayout) {
        self.layout = layout
    }

    public func body(content: Content, context: Void) -> some View {
        content
            .environment(\.toolLayout, layout)
            .tint(.accent)
    }
}

/// Shows a preview at the largest Dynamic Type size, where a layout is likeliest to break.
public struct LargestTextPreview: PreviewModifier {
    public init() {}

    public func body(content: Content, context: Void) -> some View {
        content
            .environment(\.dynamicTypeSize, .accessibility5)
            .tint(.accent)
    }
}

extension PreviewTrait where T == Preview.ViewTraits {
    /// A tool window's iPad layout, with the app's tint. Pair it with a width from 640 to the tool's
    /// Mac width.
    public static var padLayout: Self { .modifier(ToolLayoutPreview(.pad)) }
    /// A tool window's iPhone layout, with the app's tint. Pair it with a width below 640.
    public static var phoneLayout: Self { .modifier(ToolLayoutPreview(.phone)) }
    /// The largest Dynamic Type size, with the app's tint.
    public static var largestText: Self { .modifier(LargestTextPreview()) }
}
