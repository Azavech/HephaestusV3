import ChatData
import Foundation
import TextViews
import ToolsFoundation

/// The app's sound player (docs/text.md › Markers › Sounds): a sound's file from the chats' catalogues, played with
/// `SoundPlayer`, one at a time.
public enum ChatSounds {
    /// What every window's ▶ calls.
    public static func player(_ chats: ChatSession) -> PlaySoundAction {
        PlaySoundAction { name, root in
            guard let url = await chats.soundFile(named: name, projectRoot: root) else {
                return String(localized: "\(name) is not a sound of this Mac or of the project.", bundle: #bundle)
            }
            return SoundPlayer.shared.play(url)
        }
    }
}
