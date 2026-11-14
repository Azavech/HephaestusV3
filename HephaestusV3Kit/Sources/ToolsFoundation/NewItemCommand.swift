import SwiftUI

/// What the key window creates from the File menu, as in a Mac app: ⌘N opens a new window, and ⇧⌘N
/// makes the window's own kind of item, such as a ticket in Tickets or a chat in the Chat window. The
/// menu item names it ("New Ticket…"). A window without one leaves the item disabled. The app keeps the
/// Mac's behavior (the user's choice).
///
/// A window provides it with `newItemCommand(_:action:)`; ToolsScenes puts it in the File menu.
nonisolated public struct NewItemCommand {
    /// The menu item's title: "New Ticket…", with an ellipsis when it asks for more before it creates
    /// anything.
    public let title: String
    private let action: @MainActor () -> Void

    public init(_ title: String, action: @escaping @MainActor () -> Void) {
        self.title = title
        self.action = action
    }

    @MainActor
    public func callAsFunction() {
        action()
    }
}

nonisolated private struct NewItemCommandKey: FocusedValueKey {
    typealias Value = NewItemCommand
}

nonisolated extension FocusedValues {
    /// The key window's File ▸ New item; nil when the window creates nothing.
    public var newItem: NewItemCommand? {
        get { self[NewItemCommandKey.self] }
        set { self[NewItemCommandKey.self] = newValue }
    }
}

extension View {
    /// Makes File ▸ New <item> (⇧⌘N) run `action` while this view's window is the key window, under
    /// `title`.
    public func newItemCommand(_ title: String, action: @escaping @MainActor () -> Void) -> some View {
        focusedSceneValue(\.newItem, NewItemCommand(title, action: action))
    }
}
