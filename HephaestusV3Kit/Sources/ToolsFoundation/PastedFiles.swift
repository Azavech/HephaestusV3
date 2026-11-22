import AppKit
import SwiftUI

/// What ⌘V attaches in a composer, the chat's and a ticket's comment (docs/ui/chat.md › Attachments): the pasteboard's
/// files, or its image written as a PNG.
public enum PastedFiles {
    /// What a paste takes: the pasteboard's files, or its image's data as it holds it.
    public enum Paste: Equatable {
        case files([URL])
        case image(Data)
    }

    /// What the pasteboard gives, read at once, so that the key press is answered without waiting: its files, or its
    /// image's data when it holds no text; nil otherwise (text pastes as text, even beside the picture Numbers,
    /// Keynote or Word put with it, as in V2). The image is written by `write(image:now:)`, off the main actor.
    public static func take(from pasteboard: NSPasteboard = .general) -> Paste? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return .files(urls)
        }
        guard pasteboard.availableType(from: [.string]) == nil else { return nil }
        if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) { return .image(data) }
        return NSImage(pasteboard: pasteboard)?.tiffRepresentation.map(Paste.image)
    }

    /// A pasted image as a PNG written to a temporary folder, named `Pasted Image <yyyy-MM-dd> at <HH.mm.ss>.png` in
    /// local time, as Tickets names one; nil when it can't be read or written.
    nonisolated public static func write(image data: Data, now: Date) -> URL? {
        let png: Data
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            png = data
        } else if let converted = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) {
            png = converted
        } else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("HephaestusV3-Paste-\(UUID().uuidString)", isDirectory: true)
        let file = folder.appendingPathComponent("Pasted Image \(formatter.string(from: now)).png")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: file)
        } catch {
            return nil
        }
        return file
    }

    /// Removes the temporary copies of pasted images once they are sent: the chat or the ticket keeps its own.
    public static func clean(_ files: [URL]) {
        for file in files where file.lastPathComponent.hasPrefix("Pasted Image ")
            && file.deletingLastPathComponent().lastPathComponent.hasPrefix("HephaestusV3-Paste-") {
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
    }
}

#if os(macOS)
/// Sees each ⌘V of its window before the window does, while it is in the view hierarchy: `take` returning true swallows
/// the key press, so the focused field doesn't paste. AZDesign's composer has its own; a plain field puts this behind it
/// while it has the focus.
public struct PasteWatcher: NSViewRepresentable {
    let take: () -> Bool

    public init(take: @escaping () -> Bool) {
        self.take = take
    }

    public func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.attach(to: view)
        return view
    }

    public func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.take = take
    }

    public static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(take: take)
    }

    @MainActor public final class Coordinator {
        var take: () -> Bool
        private var monitor: Any?
        private weak var view: NSView?

        init(take: @escaping () -> Bool) {
            self.take = take
        }

        func attach(to view: NSView) {
            self.view = view
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                      event.charactersIgnoringModifiers == "v" else { return event }
                let windowNumber = event.windowNumber
                let taken = MainActor.assumeIsolated { self?.takes(inWindow: windowNumber) ?? false }
                return taken ? nil : event
            }
        }

        func takes(inWindow number: Int) -> Bool {
            guard let window = view?.window, window.windowNumber == number else { return false }
            return take()
        }

        func detach() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
#endif
