import AppKit

/// The TriBoost mark: three fingertips resting above a fast-forward chevron.
///
/// Drawn in code rather than shipped as a PNG so the menu bar icon stays crisp at
/// any scale factor and picks up light/dark automatically as a template image.
enum AppIcon {

    /// Draws the mark into the unit square `0...1` (y up), in the current colour.
    static func drawMark(in ctx: NSGraphicsContext, scale: CGFloat) {
        let cg = ctx.cgContext

        // Three fingertips, evenly spaced, sitting on a gentle arc.
        let dotRadius: CGFloat = 0.090
        let dots: [CGPoint] = [
            CGPoint(x: 0.205, y: 0.740),
            CGPoint(x: 0.500, y: 0.800),
            CGPoint(x: 0.795, y: 0.740),
        ]
        for dot in dots {
            let rect = CGRect(
                x: (dot.x - dotRadius) * scale,
                y: (dot.y - dotRadius) * scale,
                width: dotRadius * 2 * scale,
                height: dotRadius * 2 * scale
            )
            cg.fillEllipse(in: rect)
        }

        // A double chevron pointing right: "faster".
        let barWidth: CGFloat = 0.115
        let halfHeight: CGFloat = 0.185
        let midY: CGFloat = 0.335

        func chevron(tipX: CGFloat) {
            let path = CGMutablePath()
            let backX = tipX - 0.235
            path.move(to: CGPoint(x: backX * scale, y: (midY + halfHeight) * scale))
            path.addLine(to: CGPoint(x: tipX * scale, y: midY * scale))
            path.addLine(to: CGPoint(x: backX * scale, y: (midY - halfHeight) * scale))
            path.addLine(to: CGPoint(x: (backX + barWidth) * scale, y: (midY - halfHeight) * scale))
            path.addLine(to: CGPoint(x: (tipX + barWidth) * scale, y: midY * scale))
            path.addLine(to: CGPoint(x: (backX + barWidth) * scale, y: (midY + halfHeight) * scale))
            path.closeSubpath()
            cg.addPath(path)
            cg.fillPath()
        }

        // Centred on the same axis as the dots: the group spans 0.185...0.815.
        chevron(tipX: 0.420)
        chevron(tipX: 0.700)
    }

    /// Monochrome template image for the status bar. macOS recolours it for us, so
    /// it stays legible in light mode, dark mode and when the menu is open.
    static func menuBarImage(pointSize: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize),
                            flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current else { return false }
            NSColor.black.setFill()
            drawMark(in: ctx, scale: pointSize)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "TriBoost"
        return image
    }
}
