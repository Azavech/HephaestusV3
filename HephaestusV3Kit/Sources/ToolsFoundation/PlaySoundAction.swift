import SwiftUI

/// Plays a sound of the sound catalogue (docs/text.md › Markers › Sounds): a sound marker's ▶ calls it with the
/// sound's name and the folder of the view's project. ToolsScenes gives it to every window; it returns the
/// failure's message, which the view shows in the alert "Play Sound failed", or nil.
nonisolated public struct PlaySoundAction: Sendable {
    private let play: @MainActor @Sendable (String, String?) async -> String?

    public init(_ play: @escaping @MainActor @Sendable (String, String?) async -> String?) {
        self.play = play
    }

    @MainActor
    public func callAsFunction(_ name: String, projectRoot: String?) async -> String? {
        await play(name, projectRoot)
    }
}

nonisolated extension EnvironmentValues {
    /// The sound player; nil in previews, where a ▶ says the window can't play sounds.
    @Entry public var playSound: PlaySoundAction? = nil
}
