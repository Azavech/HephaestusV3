import AppKit

/// Renders a window into a PNG inside the app's process, without screen-capture APIs, so that no screen
/// recording permission is needed: V2's capture, without its web views, which V3 doesn't have
/// (docs/ui/tickets.md › Feedback › Screenshot).
///
/// The frame view (title bar, toolbar and content) is rendered with `cacheDisplay` at the backing scale; the
/// panes that blend with what is behind the window are filled with the window's background color; the toolbar
/// window of a window in full screen, and the window's sheets, are drawn over it. A PNG larger than
/// `maximumPNGSize` is rendered again at 1 pixel per point.
enum WindowCapture {
    /// PNGs larger than this many bytes are rendered again at 1 pixel per point, so that the screenshot leaves
    /// room for added files in the ticket's 20 MB.
    static let maximumPNGSize = 5_000_000

    /// The window's PNG; nil when no bitmap can be made. A sheet, the background window of an alert sheet, or
    /// the toolbar window of a window in full screen is captured as the window it belongs to.
    static func capture(_ requested: NSWindow) -> Data? {
        let window = hostWindow(of: requested)
        guard let root = window.contentView?.superview ?? window.contentView, !root.bounds.isEmpty else { return nil }
        if let png = render(root, of: window, onePixelPerPoint: false), png.count <= maximumPNGSize {
            return png
        }
        return render(root, of: window, onePixelPerPoint: true)
    }

    // MARK: Sheets and full screen

    /// The window a sheet is attached to, through every level of sheets; for the background window of an
    /// alert sheet (a child window of the sheet), the window of that sheet; for the toolbar window of a window
    /// in full screen, that window.
    static func hostWindow(of window: NSWindow) -> NSWindow {
        var host = window
        if let owner = NSApp.windows.first(where: { $0 !== host && fullScreenToolbarWindow(of: $0) === host }) {
            host = owner
        }
        if host.sheetParent == nil, let parent = host.parent, parent.sheetParent != nil {
            host = parent
        }
        while let parent = host.sheetParent {
            host = parent
        }
        return host
    }

    /// The windows drawn over the window, back to front: each attached sheet, through every level, after its
    /// visible child windows, the background macOS puts behind an alert sheet.
    static func overlayWindows(of window: NSWindow) -> [NSWindow] {
        var result: [NSWindow] = []
        var current = window.attachedSheet
        while let sheet = current {
            result += (sheet.childWindows ?? []).filter(\.isVisible)
            result.append(sheet)
            current = sheet.attachedSheet
        }
        return result
    }

    /// The window that holds the title bar and the toolbar of a window in full screen, which macOS moves out
    /// of the window's frame view: the visible window, other than the window itself, of its close button or
    /// else of the view of one of its toolbar items. Nil when the window isn't in full screen.
    static func fullScreenToolbarWindow(of window: NSWindow) -> NSWindow? {
        guard window.styleMask.contains(.fullScreen) else { return nil }
        let holders = [window.standardWindowButton(.closeButton)?.window] + (window.toolbar?.items ?? []).map { $0.view?.window }
        return holders.lazy.compactMap { $0 }.first { $0 !== window && $0.isVisible }
    }

    /// Where a window drawn over the captured one goes in its bitmap, in points from the captured window's
    /// bottom-left corner: at its place on screen.
    static func placement(of overlay: NSRect, in window: NSRect) -> NSRect {
        NSRect(x: overlay.minX - window.minX, y: overlay.minY - window.minY, width: overlay.width, height: overlay.height)
    }

    // MARK: Rendering

    private static func render(_ root: NSView, of window: NSWindow, onePixelPerPoint: Bool) -> Data? {
        guard let bitmap = bitmap(of: root, onePixelPerPoint: onePixelPerPoint) else { return nil }
        let panes = frostedPanes(in: root)
        let overlays = [fullScreenToolbarWindow(of: window)].compactMap { $0 } + overlayWindows(of: window)
        if !panes.isEmpty || !overlays.isEmpty, let context = NSGraphicsContext(bitmapImageRep: bitmap) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            fill(panes, of: root)
            for overlay in overlays {
                guard let overlayRoot = overlay.contentView?.superview ?? overlay.contentView, !overlayRoot.bounds.isEmpty,
                      let image = Self.bitmap(of: overlayRoot, onePixelPerPoint: onePixelPerPoint)
                else { continue }
                let rect = placement(of: overlay.frame, in: window.frame)
                image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    /// The visible views of the root that blend with what is behind the window; `cacheDisplay` leaves their
    /// area transparent.
    private static func frostedPanes(in view: NSView) -> [NSVisualEffectView] {
        if let effect = view as? NSVisualEffectView, effect.blendingMode == .behindWindow {
            return effect.isHiddenOrHasHiddenAncestor || effect.visibleRect.isEmpty ? [] : [effect]
        }
        return view.subviews.flatMap { frostedPanes(in: $0) }
    }

    /// Fills each pane's visible area behind the rendered pixels with the window background color of the
    /// pane's appearance, so that the pane shows opaque in the PNG.
    private static func fill(_ panes: [NSVisualEffectView], of root: NSView) {
        for pane in panes {
            var rect = pane.convert(pane.visibleRect, to: root)
            if root.isFlipped {
                rect.origin.y = root.bounds.height - rect.maxY
            }
            pane.effectiveAppearance.performAsCurrentDrawingAppearance {
                NSColor.windowBackgroundColor.setFill()
                rect.fill(using: .destinationOver)
            }
        }
    }

    /// The view rendered with `cacheDisplay`, at the backing scale or at 1 pixel per point.
    private static func bitmap(of root: NSView, onePixelPerPoint: Bool) -> NSBitmapImageRep? {
        let bounds = root.bounds
        let bitmap: NSBitmapImageRep
        if onePixelPerPoint {
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width.rounded(.up)),
                                             pixelsHigh: Int(bounds.height.rounded(.up)), bitsPerSample: 8, samplesPerPixel: 4,
                                             hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                             bitsPerPixel: 0) else { return nil }
            rep.size = bounds.size
            bitmap = rep
        } else {
            guard let rep = root.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
            bitmap = rep
        }
        root.cacheDisplay(in: bounds, to: bitmap)
        return bitmap
    }
}
