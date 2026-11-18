import AppKit
import AZDesign
import CoreText
import SwiftUI
import TextFormats

/// How a color value of the markers and the color card draws on the Mac (docs/text.md › Markers › Colors), as V2
/// drew it: a hex color as itself; a SwiftUI name as the AppKit color SwiftUI draws on the Mac; a UIKit name as the
/// AppKit color of the same name, or UIKit's light and dark values when AppKit has none; an AppKit name as itself.
/// The colors are the user's data, drawn as they are, never the app's own.
public enum ColorSwatches {
    /// The color, following the appearance it draws in; nil for a value that is neither a hex color nor a system
    /// color name.
    public static func nsColor(_ value: String) -> NSColor? {
        if let components = SystemColors.components(ofHex: value), SystemColors.isHex(value) {
            return NSColor(srgbRed: components.red, green: components.green, blue: components.blue, alpha: 1)
        }
        if let named = named[value] { return named }
        if value == "tintColor" { return .controlAccentColor }
        if let values = SystemColors.uiKitValues[value], let light = hex(values.light), let dark = hex(values.dark) {
            return NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            }
        }
        return nil
    }

    /// The color as SwiftUI draws it, following the appearance.
    public static func color(_ value: String) -> Color? {
        nsColor(value).map(Color.init(nsColor:))
    }

    /// The color resolved in a light or dark appearance.
    public static func resolved(_ value: String, dark: Bool) -> NSColor? {
        guard let color = nsColor(value) else { return nil }
        var result = color
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            result = color.usingColorSpace(.sRGB) ?? color
        }
        return result
    }

    /// A swatch for text: a rounded square of the color, `size` points, with a hairline border, in the
    /// appearance given.
    static func swatchImage(_ value: String, dark: Bool, size: CGFloat = 11) -> NSImage? {
        guard let fill = resolved(value, dark: dark) else { return nil }
        let border = NSColor(Color.textSecondary).withAlphaComponent(0.4)
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 2.5, yRadius: 2.5)
            fill.setFill()
            path.fill()
            NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
                border.setStroke()
            }
            path.lineWidth = 1
            path.stroke()
            return true
        }
        return image
    }

    private static func hex(_ value: String) -> NSColor? {
        SystemColors.components(ofHex: value).map { NSColor(srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: $0.alpha) }
    }

    /// The SwiftUI, standard, UIKit and AppKit names AppKit draws.
    private static let named: [String: NSColor] = [
        "red": .systemRed, "orange": .systemOrange, "yellow": .systemYellow, "green": .systemGreen, "mint": .systemMint,
        "teal": .systemTeal, "cyan": .systemCyan, "blue": .systemBlue, "indigo": .systemIndigo, "purple": .systemPurple,
        "pink": .systemPink, "brown": .systemBrown, "gray": .systemGray, "black": .black, "white": .white,
        "primary": .labelColor, "secondary": .secondaryLabelColor, "accentColor": .controlAccentColor,
        "systemRed": .systemRed, "systemOrange": .systemOrange, "systemYellow": .systemYellow, "systemGreen": .systemGreen,
        "systemMint": .systemMint, "systemTeal": .systemTeal, "systemCyan": .systemCyan, "systemBlue": .systemBlue,
        "systemIndigo": .systemIndigo, "systemPurple": .systemPurple, "systemPink": .systemPink, "systemBrown": .systemBrown,
        "systemGray": .systemGray,
        "label": .labelColor, "secondaryLabel": .secondaryLabelColor, "tertiaryLabel": .tertiaryLabelColor,
        "quaternaryLabel": .quaternaryLabelColor, "placeholderText": .placeholderTextColor, "link": .linkColor,
        "separator": .separatorColor, "systemFill": .systemFill, "secondarySystemFill": .secondarySystemFill,
        "tertiarySystemFill": .tertiarySystemFill, "quaternarySystemFill": .quaternarySystemFill,
        "quinaryLabelColor": .quinaryLabel, "quinarySystemFillColor": .quinarySystemFill, "textColor": .textColor,
        "textBackgroundColor": .textBackgroundColor, "textInsertionPointColor": .textInsertionPointColor,
        "selectedTextColor": .selectedTextColor, "selectedTextBackgroundColor": .selectedTextBackgroundColor,
        "unemphasizedSelectedTextColor": .unemphasizedSelectedTextColor,
        "unemphasizedSelectedTextBackgroundColor": .unemphasizedSelectedTextBackgroundColor,
        "keyboardFocusIndicatorColor": .keyboardFocusIndicatorColor, "windowBackgroundColor": .windowBackgroundColor,
        "windowFrameTextColor": .windowFrameTextColor, "underPageBackgroundColor": .underPageBackgroundColor,
        "controlBackgroundColor": .controlBackgroundColor, "controlAccentColor": .controlAccentColor, "controlColor": .controlColor,
        "controlTextColor": .controlTextColor, "selectedControlColor": .selectedControlColor,
        "selectedControlTextColor": .selectedControlTextColor, "disabledControlTextColor": .disabledControlTextColor,
        "alternateSelectedControlTextColor": .alternateSelectedControlTextColor,
        "selectedContentBackgroundColor": .selectedContentBackgroundColor,
        "unemphasizedSelectedContentBackgroundColor": .unemphasizedSelectedContentBackgroundColor,
        "selectedMenuItemTextColor": .selectedMenuItemTextColor, "headerTextColor": .headerTextColor, "gridColor": .gridColor,
        "findHighlightColor": .findHighlightColor, "highlightColor": .highlightColor, "shadowColor": .shadowColor,
    ]
}

/// The fonts of the font notation as the Mac draws them (docs/text.md › Markers › Fonts): the system font's designs,
/// the installed families, and the faces of a project's font files once the app read them.
public enum FontFaces {
    /// A project's face: its file and PostScript name.
    struct ProjectFace: Hashable {
        var file: URL
        var postScriptName: String
    }

    /// The project faces read, by family then style name.
    private static var projectFaces: [String: [String: ProjectFace]] = [:]

    /// Remembers a face of a project's font file, so that markers and cards draw it.
    public static func register(family: String, style: String, file: URL, postScriptName: String) {
        projectFaces[family, default: [:]][style] = ProjectFace(file: file, postScriptName: postScriptName)
    }

    /// The SwiftUI weights of the system designs' weight names.
    public static let systemWeights: [String: Font.Weight] = [
        "Ultralight": .ultraLight, "Thin": .thin, "Light": .light, "Regular": .regular, "Medium": .medium,
        "Semibold": .semibold, "Bold": .bold, "Heavy": .heavy, "Black": .black,
    ]

    /// The designs of the system designs' names.
    public static let systemDesigns: [String: Font.Design] = [
        "System": .default, "System Rounded": .rounded, "System Serif": .serif, "System Monospaced": .monospaced,
    ]

    /// A family font at `size` points: a system design, an installed face, or a project face read; nil when the
    /// Mac can't draw it.
    public static func font(family: String, weight: String, size: CGFloat) -> Font? {
        if let design = systemDesigns[family] {
            guard let weight = systemWeights[weight] else { return nil }
            return .system(size: size, weight: weight, design: design)
        }
        return ctFont(family: family, weight: weight, size: size).map { Font($0) }
    }

    /// An installed or project face as CoreText draws it.
    public static func ctFont(family: String, weight: String, size: CGFloat) -> CTFont? {
        let attributes = [kCTFontFamilyNameAttribute: family, kCTFontStyleNameAttribute: weight] as CFDictionary
        let request = CTFontDescriptorCreateWithAttributes(attributes)
        let mandatory = Set([kCTFontFamilyNameAttribute as String, kCTFontStyleNameAttribute as String]) as CFSet
        if let match = CTFontDescriptorCreateMatchingFontDescriptor(request, mandatory) {
            return CTFontCreateWithFontDescriptor(match, size, nil)
        }
        guard let face = projectFaces[family]?[weight],
              let descriptors = CTFontManagerCreateFontDescriptorsFromURL(face.file as CFURL) as? [CTFontDescriptor] else { return nil }
        let descriptor = descriptors.first { (CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String) == face.postScriptName }
        return descriptor.map { CTFontCreateWithFontDescriptor($0, size, nil) }
    }

    /// A text style's font.
    public static func font(_ style: FontTextStyle) -> Font {
        switch style {
        case .largeTitle: .largeTitle
        case .title: .title
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .body: .body
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption
        case .caption2: .caption2
        }
    }

    /// A marker's font: its family and weight, or its text style's weight, at the size of the body text around it.
    static func markerFont(_ notation: FontNotation) -> Font? {
        let size = NSFont.preferredFont(forTextStyle: .body).pointSize
        switch notation {
        case .textStyle(let style):
            return switch style {
            case .headline: .body.bold()
            case .caption2: .body.weight(.medium)
            default: .body
            }
        case .family(let family, let weight, _):
            return font(family: family, weight: weight, size: size)
        }
    }
}

/// Plays the sounds of the markers and the sound card, one at a time in the app (docs/text.md › Markers ›
/// Sounds): starting a sound stops the one that plays.
public final class SoundPlayer {
    public static let shared = SoundPlayer()
    private var current: NSSound?

    /// Plays the file; the message of the failure when it can't be played.
    public func play(_ url: URL) -> String? {
        current?.stop()
        guard let sound = NSSound(contentsOf: url, byReference: false) else {
            current = nil
            return String(localized: "The sound cannot be played.", bundle: #bundle)
        }
        current = sound
        sound.play()
        return nil
    }
}

/// The `href` of a sound marker's ▶: `hephaestus-sound:` and the percent-encoded name.
enum SoundLinks {
    static let scheme = "hephaestus-sound"

    static func href(for name: String) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return URL(string: scheme + ":" + (name.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""))
    }

    static func name(from url: URL) -> String? {
        let text = url.absoluteString
        guard text.hasPrefix(scheme + ":") else { return nil }
        return String(text.dropFirst(scheme.count + 1)).removingPercentEncoding
    }
}

/// A text that reads markers and ids as plain text (docs/text.md › Markers): a suggestion's line or an answer in
/// the chat's cards. Ids link to their tickets and ▶ plays its sound, as in `MarkdownView`.
public struct MarkerText: View {
    let inlines: [MarkdownInline]
    let root: String?

    @Environment(\.colorScheme) private var colorScheme

    /// `text` with its markers, and with the ids of `projects` linked. Without `playsSounds`, a sound marker's ▶
    /// is text, so that a click on it reaches the row around it.
    public init(_ text: String, projects: Set<String> = [], root: String? = nil, playsSounds: Bool = true) {
        let inlines = MarkdownMarkers.inlines(in: text, options: MarkdownView.markerOptions, projectIdentifiers: projects)
        self.inlines = playsSounds ? inlines : inlines.map { inline in
            if case .sound(let name) = inline { return .text("▶ " + name) }
            return inline
        }
        self.root = root
    }

    public var body: some View {
        MarkdownInlines.text(inlines, dark: colorScheme == .dark)
            .modifier(MarkdownLinkActions(root: root, options: MarkdownRenderOptions(projectRootPath: root)))
    }
}
