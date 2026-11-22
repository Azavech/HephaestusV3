import SwiftUI
import ToolsScenes

/// The app target stays thin: every scene, window and command lives in HephaestusV3Kit.
@main
struct HephaestusV3App: App {
    @NSApplicationDelegateAdaptor(HephaestusAppDelegate.self) private var delegate

    var body: some Scene {
        ToolsScenes()
    }
}
