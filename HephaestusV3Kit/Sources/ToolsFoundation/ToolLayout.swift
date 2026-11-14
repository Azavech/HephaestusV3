import SwiftUI

/// The size classes of a window, as iPadOS and iOS set them for an app's window, worked out from the
/// window's size (the user's choice: every window conforms to the system's compact and regular sizes).
///
/// - Width: **compact** below 640 points, as an iPhone held upright or a narrow iPad window; **regular**
///   from 640, as an iPad, or an iPhone held sideways.
/// - Height: **compact** below 500 points, as an iPhone held sideways; **regular** from 500.
///
/// A window writes them into the system's own environment values, `horizontalSizeClass` and
/// `verticalSizeClass`, with `windowSizeClasses(_:)`, so views read them as they would on iPad or iPhone.
nonisolated public struct WindowSizeClasses: Sendable, Hashable {
    public var horizontal: UserInterfaceSizeClass
    public var vertical: UserInterfaceSizeClass

    /// Below this width, a window's width is compact.
    public static let compactWidth: CGFloat = 640
    /// Below this height, a window's height is compact.
    public static let compactHeight: CGFloat = 500

    public init(horizontal: UserInterfaceSizeClass, vertical: UserInterfaceSizeClass) {
        self.horizontal = horizontal
        self.vertical = vertical
    }

    /// The size classes of a window `size` points large.
    public init(size: CGSize) {
        horizontal = size.width < Self.compactWidth ? .compact : .regular
        vertical = size.height < Self.compactHeight ? .compact : .regular
    }

    /// A window not measured yet: wide and tall.
    public static let regular = WindowSizeClasses(horizontal: .regular, vertical: .regular)
}

extension View {
    /// Gives this view's content the window's size classes, in the system's environment values.
    public func windowSizeClasses(_ classes: WindowSizeClasses) -> some View {
        environment(\.horizontalSizeClass, classes.horizontal)
            .environment(\.verticalSizeClass, classes.vertical)
    }
}

/// How a tool window lays itself out for the room it has, after the three platforms:
///
/// - `phone`: compact width, as an iPhone does: one pane at a time, a list, then an item's page over
///   it, with Back.
/// - `pad`: regular width without the room for every column, as an iPad does: panels slide over the
///   content instead of taking room from it, and side columns fold away behind their button.
/// - `mac`: regular width with the room for every column and panel side by side.
///
/// The window measures itself and decides; each tool reads `toolLayout` and adapts its own panes, and
/// reads the system's `verticalSizeClass` where a short window needs its own arrangement.
nonisolated public enum ToolLayout: Sendable, Hashable {
    case mac
    case pad
    case phone

    /// Below this width, a window shows one pane at a time: its width is compact.
    public static let phoneWidth: CGFloat = WindowSizeClasses.compactWidth

    /// The layout for a window `width` points wide, whose tool needs `macWidth` points for its columns
    /// side by side, plus the side panel's room when one is open beside it.
    public static func forWidth(_ width: CGFloat, macWidth: CGFloat, panelWidth: CGFloat = 0) -> ToolLayout {
        if width < phoneWidth { return .phone }
        return width >= macWidth + panelWidth ? .mac : .pad
    }
}

nonisolated private struct CollapsedFromRegularWidthKey: EnvironmentKey {
    static let defaultValue = false
}

nonisolated extension EnvironmentValues {
    /// Whether the window narrowed to compact width after showing a regular one. A `PhoneStack` then
    /// opens on the selected item's page, as an iPad's split view keeps its selection when it
    /// collapses. A window opened narrow starts on its list instead.
    public var collapsedFromRegularWidth: Bool {
        get { self[CollapsedFromRegularWidthKey.self] }
        set { self[CollapsedFromRegularWidthKey.self] = newValue }
    }
}

nonisolated private struct ToolLayoutKey: EnvironmentKey {
    static let defaultValue = ToolLayout.mac
}

nonisolated extension EnvironmentValues {
    /// How the window lays its tool out. Previews and other windows get the Mac's.
    public var toolLayout: ToolLayout {
        get { self[ToolLayoutKey.self] }
        set { self[ToolLayoutKey.self] = newValue }
    }
}

/// One pane at a time, as an iPhone shows a list: `list`, then the page of the item picked in it,
/// pushed over the list with a Back button. Going back clears the selection, so picking the same
/// item again opens its page again. `opensSelection` starts on the selected item's page: for a window
/// opened on an item, such as a ticket from a link; without it the list starts with nothing selected.
public struct PhoneStack<ID: Hashable, List: View, Page: View>: View {
    @Binding var selection: ID?
    let opensSelection: Bool
    let list: List
    let page: (ID) -> Page

    @State private var path: [ID] = []
    @Environment(\.collapsedFromRegularWidth) private var collapsedFromRegularWidth

    public init(
        selection: Binding<ID?>, opensSelection: Bool = false,
        @ViewBuilder list: () -> List, @ViewBuilder page: @escaping (ID) -> Page
    ) {
        _selection = selection
        self.opensSelection = opensSelection
        self.list = list()
        self.page = page
        _path = State(initialValue: opensSelection ? selection.wrappedValue.map { [$0] } ?? [] : [])
    }

    public var body: some View {
        NavigationStack(path: $path) {
            list
                .navigationDestination(for: ID.self) { id in
                    page(id)
                }
        }
        .onChange(of: selection) { _, picked in
            if let picked, path.last != picked {
                path = [picked]
            }
        }
        .onChange(of: path) { _, path in
            if path.isEmpty {
                selection = nil
            }
        }
        .onAppear {
            if collapsedFromRegularWidth, let selection {
                // A window that narrowed keeps its selection and shows its page, as a collapsing split
                // view does.
                path = [selection]
            } else if !opensSelection {
                // A list opened on no item starts with none selected: a row that started selected
                // would not open its page, since only a change of the selection does.
                selection = nil
            }
        }
    }
}
