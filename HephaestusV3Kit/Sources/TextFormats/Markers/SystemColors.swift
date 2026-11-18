import Foundation

/// The light and dark values of a color, hex colors `#RRGGBB` or `#RRGGBBAA`.
public struct SystemColorValues: Sendable, Hashable {
    public var light: String
    public var dark: String

    public init(light: String, dark: String) {
        self.light = light
        self.dark = dark
    }
}

/// The system color names of docs/text.md › System colors, as V2 listed them, and the check of a color: a hex
/// color `#RRGGBB` or a system color name. The chats check `ask_color`'s colors with it; the color card lists
/// its names, and the renderers accept color markers with it.
public enum SystemColors {
    /// The SwiftUI standard colors.
    public static let swiftUI = [
        "red", "orange", "yellow", "green", "mint", "teal", "cyan", "blue", "indigo", "purple", "pink", "brown", "gray",
        "black", "white", "primary", "secondary", "accentColor",
    ]

    /// The UIKit and AppKit standard colors.
    public static let standard = [
        "systemRed", "systemOrange", "systemYellow", "systemGreen", "systemMint", "systemTeal", "systemCyan", "systemBlue",
        "systemIndigo", "systemPurple", "systemPink", "systemBrown", "systemGray", "systemGray2", "systemGray3", "systemGray4",
        "systemGray5", "systemGray6",
    ]

    /// The UIKit semantic colors, by their UIKit name.
    public static let uiKitSemantic = [
        "label", "secondaryLabel", "tertiaryLabel", "quaternaryLabel", "placeholderText", "link", "separator",
        "opaqueSeparator", "systemFill", "secondarySystemFill", "tertiarySystemFill", "quaternarySystemFill",
        "systemBackground", "secondarySystemBackground", "tertiarySystemBackground", "systemGroupedBackground",
        "secondarySystemGroupedBackground", "tertiarySystemGroupedBackground", "tintColor", "darkText", "lightText",
    ]

    /// The AppKit semantic colors that UIKit lacks, by their AppKit name with its `Color` suffix.
    public static let appKitSemantic = [
        "quinaryLabelColor", "quinarySystemFillColor", "textColor", "textBackgroundColor", "textInsertionPointColor",
        "selectedTextColor", "selectedTextBackgroundColor", "unemphasizedSelectedTextColor",
        "unemphasizedSelectedTextBackgroundColor", "keyboardFocusIndicatorColor", "windowBackgroundColor",
        "windowFrameTextColor", "underPageBackgroundColor", "controlBackgroundColor", "controlAccentColor", "controlColor",
        "controlTextColor", "selectedControlColor", "selectedControlTextColor", "disabledControlTextColor",
        "alternateSelectedControlTextColor", "selectedContentBackgroundColor", "unemphasizedSelectedContentBackgroundColor",
        "selectedMenuItemTextColor", "headerTextColor", "gridColor", "findHighlightColor", "highlightColor", "shadowColor",
    ]

    /// Every name, in the order of the color card's grid.
    public static let names = swiftUI + standard + uiKitSemantic + appKitSemantic

    private static let nameSet = Set(names)

    /// UIKit's values on iOS of the UIKit names AppKit lacks, `tintColor` excepted.
    public static let uiKitValues: [String: SystemColorValues] = [
        "systemGray2": SystemColorValues(light: "#AEAEB2", dark: "#636366"),
        "systemGray3": SystemColorValues(light: "#C7C7CC", dark: "#48484A"),
        "systemGray4": SystemColorValues(light: "#D1D1D6", dark: "#3A3A3C"),
        "systemGray5": SystemColorValues(light: "#E5E5EA", dark: "#2C2C2E"),
        "systemGray6": SystemColorValues(light: "#F2F2F7", dark: "#1C1C1E"),
        "opaqueSeparator": SystemColorValues(light: "#C6C6C8", dark: "#38383A"),
        "systemBackground": SystemColorValues(light: "#FFFFFF", dark: "#000000"),
        "secondarySystemBackground": SystemColorValues(light: "#F2F2F7", dark: "#1C1C1E"),
        "tertiarySystemBackground": SystemColorValues(light: "#FFFFFF", dark: "#2C2C2E"),
        "systemGroupedBackground": SystemColorValues(light: "#F2F2F7", dark: "#000000"),
        "secondarySystemGroupedBackground": SystemColorValues(light: "#FFFFFF", dark: "#1C1C1E"),
        "tertiarySystemGroupedBackground": SystemColorValues(light: "#F2F2F7", dark: "#2C2C2E"),
        "darkText": SystemColorValues(light: "#000000", dark: "#000000"),
        "lightText": SystemColorValues(light: "#FFFFFF99", dark: "#FFFFFF99"),
    ]

    /// Whether the text is a system color name, compared with its letter case.
    public static func isName(_ text: String) -> Bool {
        nameSet.contains(text)
    }

    /// Whether the text is a hex color: `#` followed by six hex digits in either letter case.
    public static func isHex(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count == 7, scalars[0] == "#" else { return false }
        return scalars.dropFirst().allSatisfy(isHexDigit)
    }

    /// Whether the text is a color: a hex color or a system color name.
    public static func isColor(_ text: String) -> Bool {
        isHex(text) || isName(text)
    }

    /// The color as the card writes it: a hex color in uppercase, a name unchanged.
    public static func normalized(_ color: String) -> String {
        isHex(color) ? color.uppercased() : color
    }

    /// Two colors are the same when their hex digits are equal ignoring letter case, or when they are the same
    /// text.
    public static func isSame(_ lhs: String, _ rhs: String) -> Bool {
        if isHex(lhs), isHex(rhs) { return lhs.uppercased() == rhs.uppercased() }
        return lhs == rhs
    }

    /// The red, green, blue and alpha components of a hex color `#RRGGBB` or `#RRGGBBAA`, from 0 to 1; nil for
    /// another text.
    public static func components(ofHex color: String) -> (red: Double, green: Double, blue: Double, alpha: Double)? {
        let scalars = Array(color.unicodeScalars)
        guard scalars.count == 7 || scalars.count == 9, scalars[0] == "#", scalars.dropFirst().allSatisfy(isHexDigit),
              let value = UInt64(String(color.dropFirst()), radix: 16) else { return nil }
        let hasAlpha = scalars.count == 9
        let rgb = hasAlpha ? value >> 8 : value
        let alpha = hasAlpha ? Double(value & 0xFF) / 255 : 1
        return (Double((rgb >> 16) & 0xFF) / 255, Double((rgb >> 8) & 0xFF) / 255, Double(rgb & 0xFF) / 255, alpha)
    }

    private static func isHexDigit(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "0"..."9", "a"..."f", "A"..."F": true
        default: false
        }
    }
}
