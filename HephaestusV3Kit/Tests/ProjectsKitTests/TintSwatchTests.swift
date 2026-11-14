import AppKit
import SwiftUI
import Testing
import ToolsFoundation
@testable import ProjectsKit

@Suite("Tint swatches")
@MainActor
struct TintSwatchTests {
    /// The color at the swatch's center, drawn in Dark Mode's appearance.
    static func center(_ image: NSImage) -> NSColor? {
        let size = 12
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                                            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        }
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.colorAt(x: size / 2, y: size / 2)
    }

    @Test("Each tint's swatch is drawn in its own color, not as a template the menu recolors")
    func swatches() throws {
        var colors: [String] = []
        for tint in ProjectTint.allCases {
            let image = TintSwatch.nsImage(tint.color)
            #expect(!image.isTemplate)
            let color = try #require(Self.center(image)?.usingColorSpace(.deviceRGB))
            #expect(color.alphaComponent > 0.9)
            colors.append(String(format: "%.2f %.2f %.2f", color.redComponent, color.greenComponent, color.blueComponent))
        }
        #expect(Set(colors).count == ProjectTint.allCases.count, "Every tint draws a different color: \(colors)")
    }
}
