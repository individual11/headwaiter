import AppKit
import SwiftUI

/// Draws the status item as one template image: the bow tie, server count, and a "something
/// changed" dot. A single template image keeps the menu bar's own tinting (light, dark,
/// highlighted) correct, which a SwiftUI HStack label doesn't reliably do. Because it's a
/// template, the dot can't be colored; it's cut out of the symbol with a clear ring instead.
enum MenuBarIcon {
    /// The bow tie glyph (GlyphRefinedTie) as a bitmap at 2× for Retina, sized in points.
    @MainActor private static var tieImage: NSImage?
    @MainActor private static var tie: NSImage {
        if let tieImage { return tieImage }
        let points = NSSize(width: 22, height: 11.6)   // the 19 × 10 glyph, scaled up 1.16×
        let content = AnyView(GlyphRefinedTie().scaleEffect(1.16).frame(width: points.width, height: points.height))
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage()
        image.size = points
        tieImage = image
        return image
    }

    private struct Key: Hashable { var count: Int; var changed: Bool }
    @MainActor private static var cache: [Key: NSImage] = [:]

    @MainActor
    static func image(count: Int, changed: Bool = false) -> NSImage {
        let key = Key(count: min(count, 100), changed: changed)
        if let cached = cache[key] { return cached }
        let image = render(count: count, changed: changed)
        cache[key] = image
        return image
    }

    @MainActor
    private static func render(count: Int, changed: Bool) -> NSImage {
        let symbol = tie

        let text = count > 0 ? NSAttributedString(string: count > 99 ? "99+" : "\(count)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.black,
        ]) : nil

        let gap: CGFloat = 4
        let dot: CGFloat = 5
        let ring: CGFloat = 1.5
        let textSize = text?.size() ?? .zero
        let height: CGFloat = 18
        // Room on the right of the symbol for the dot to overhang slightly.
        let symbolWidth = symbol.size.width + (changed ? 5 : 0)
        let width = ceil(symbolWidth + (text == nil ? 0 : gap + textSize.width))

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            let symbolRect = NSRect(x: 0, y: (height - symbol.size.height) / 2,
                                    width: symbol.size.width, height: symbol.size.height)
            // Template images keep alpha, so a faded draw reads as "dimmed" in any appearance.
            symbol.draw(in: symbolRect, from: .zero, operation: .sourceOver, fraction: count > 0 ? 1 : 0.45)

            if changed, let context = NSGraphicsContext.current {
                let center = NSPoint(x: symbolRect.maxX + 2.5, y: symbolRect.maxY - 0.5)
                let outer = NSRect(x: center.x - dot / 2 - ring, y: center.y - dot / 2 - ring,
                                   width: dot + ring * 2, height: dot + ring * 2)
                context.compositingOperation = .clear
                NSBezierPath(ovalIn: outer).fill()
                context.compositingOperation = .sourceOver
                NSColor.black.setFill()
                NSBezierPath(ovalIn: outer.insetBy(dx: ring, dy: ring)).fill()
            }
            text?.draw(at: NSPoint(x: symbolWidth + gap, y: (height - textSize.height) / 2))
            return true
        }
        image.isTemplate = true
        var description = count == 0 ? "No dev servers running"
            : "\(count) dev server\(count == 1 ? "" : "s") running"
        if changed { description += ", changes since last opened" }
        image.accessibilityDescription = description
        return image
    }
}
