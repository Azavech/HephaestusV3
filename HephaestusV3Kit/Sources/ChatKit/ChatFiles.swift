import AppKit
import ChatData
import Foundation
import UniformTypeIdentifiers

/// The files waiting to go with the next message, as V2's composer took them (docs/ui/chat.md › Attachments):
/// added with Add Files…, dropped on the chat, or pasted.
enum ChatFiles {
    /// `files` with `added` after them, each once, and why some weren't added: a folder, or a file over the
    /// limits (as `MessageAttachment.check` says).
    static func adding(_ added: [URL], to files: [URL]) -> (files: [URL], failure: String?) {
        // Only files that are there: a web link or a picture dragged from a browser, or a file gone since, would
        // make a chip that can't be sent.
        if let link = added.first(where: { !$0.isFileURL }) {
            return (files, String(localized: "Only files can be attached, not \(link.absoluteString).", bundle: #bundle))
        }
        if let missing = added.first(where: { (try? $0.checkResourceIsReachable()) != true }) {
            return (files, String(localized: "\(missing.lastPathComponent) can't be read.", bundle: #bundle))
        }
        var result = files
        for url in added where !result.contains(url) {
            result.append(url)
        }
        do throws(ChatError) {
            try MessageAttachment.check(result)
            return (result, nil)
        } catch {
            return (files, error.description)
        }
    }

    /// What a paste takes: the pasteboard's files, or its image's data as it holds it.
    enum Paste: Equatable {
        case files([URL])
        case image(Data)
    }

    /// What the pasteboard gives, read at once, so that the key press is answered without waiting: its files, or its
    /// image's data when it holds no text; nil otherwise (text pastes as text, even beside the picture Numbers,
    /// Keynote or Word put with it, as in V2). The image is written by `write(image:now:)`, off the main actor.
    static func take(from pasteboard: NSPasteboard = .general) -> Paste? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return .files(urls)
        }
        guard pasteboard.availableType(from: [.string]) == nil else { return nil }
        if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) { return .image(data) }
        return NSImage(pasteboard: pasteboard)?.tiffRepresentation.map(Paste.image)
    }

    /// A pasted image as a PNG written to a temporary folder, named `Pasted Image <yyyy-MM-dd> at <HH.mm.ss>.png` in
    /// local time, as Tickets names one; nil when it can't be read or written.
    nonisolated static func write(image data: Data, now: Date) -> URL? {
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

    /// Removes the temporary copies of pasted images once they are sent: the chat keeps its own.
    static func clean(_ files: [URL]) {
        for file in files where file.lastPathComponent.hasPrefix("Pasted Image ")
            && file.deletingLastPathComponent().lastPathComponent.hasPrefix("HephaestusV3-Paste-") {
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
    }
}

import SwiftUI
import AZDesign

/// A file waiting to go with the next message: its type's icon, its name and size, and a button that takes it off.
struct PendingFileChip: View {
    let url: URL
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            FileFacts(url: url, iconSize: 14)
                .truncationMode(.middle)
            Button(String(localized: "Remove \(url.lastPathComponent)", bundle: #bundle), systemImage: "xmark", action: remove)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .font(.caption2)
                .foregroundStyle(.textSecondary)
                .help(String(localized: "Remove \(url.lastPathComponent)", bundle: #bundle))
                .accessibilityIdentifier("chat.composer.file.\(url.lastPathComponent).remove")
        }
        .font(.caption)
        .foregroundStyle(.textPrimary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.surfaceSunken, in: Capsule())
        .frame(maxWidth: 240)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.composer.file.\(url.lastPathComponent)")
    }
}

/// The composer's Add Files… button: `paperclip`, which opens a file panel for several files.
struct AddFilesButton: View {
    let add: () -> Void

    var body: some View {
        Button(String(localized: "Add Files…", bundle: #bundle, comment: "Adds files to the next message"), systemImage: "paperclip", action: add)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help(String(localized: "Add Files…", bundle: #bundle))
            .accessibilityIdentifier("chat.composer.addFiles")
    }
}

/// A file's icon, name and size, read once per file rather than at each draw: a composer draws at every key typed.
struct FileFacts: View {
    let url: URL
    let iconSize: CGFloat

    @State private var icon: NSImage?
    @State private var size: Int?

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
            } else {
                Image(systemName: "doc")
            }
        }
        .frame(width: iconSize, height: iconSize)
        .accessibilityHidden(true)
        .task(id: url) {
            icon = NSWorkspace.shared.icon(forFile: url.path)
            let url = url
            size = await Task.detached { try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize }.value
        }
        Text(verbatim: url.lastPathComponent)
            .lineLimit(1)
        if let size {
            Text(Int64(size), format: .byteCount(style: .file))
                .foregroundStyle(.textSecondary)
        }
    }
}
