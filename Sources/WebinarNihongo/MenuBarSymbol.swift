import AppKit

// Draw at the display's native scale, rather than shrinking the browser's PNG.
// NSImage's logical size also controls MenuBarExtra, which may ignore SwiftUI frames.
@MainActor enum MenuBarSymbol {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            defer { context.restoreGState() }
            context.translateBy(x: 9, y: 9)
            context.scaleBy(x: 0.024, y: 0.024)
            context.translateBy(x: -512, y: -512)
            context.setStrokeColor(NSColor.black.cgColor)
            context.setFillColor(NSColor.black.cgColor)
            context.setLineWidth(58)
            context.setLineCap(.round)
            for (start, first, second, end) in [
                (CGPoint(x: 310, y: 282), CGPoint(x: 177, y: 409), CGPoint(x: 177, y: 615), CGPoint(x: 310, y: 742)),
                (CGPoint(x: 380, y: 365), CGPoint(x: 297, y: 446), CGPoint(x: 297, y: 578), CGPoint(x: 380, y: 659)),
                (CGPoint(x: 714, y: 282), CGPoint(x: 847, y: 409), CGPoint(x: 847, y: 615), CGPoint(x: 714, y: 742)),
                (CGPoint(x: 644, y: 365), CGPoint(x: 727, y: 446), CGPoint(x: 727, y: 578), CGPoint(x: 644, y: 659))
            ] {
                context.move(to: start)
                context.addCurve(to: end, control1: first, control2: second)
                context.strokePath()
            }
            for reflected in [false, true] {
                context.saveGState()
                if reflected { context.translateBy(x: 1024, y: 0); context.scaleBy(x: -1, y: 1) }
                context.move(to: CGPoint(x: 410, y: 453))
                context.addCurve(to: CGPoint(x: 439, y: 439), control1: CGPoint(x: 410, y: 435), control2: CGPoint(x: 424, y: 430))
                context.addLine(to: CGPoint(x: 482, y: 497))
                context.addQuadCurve(to: CGPoint(x: 482, y: 527), control: CGPoint(x: 504, y: 512))
                context.addLine(to: CGPoint(x: 439, y: 585))
                context.addCurve(to: CGPoint(x: 410, y: 571), control1: CGPoint(x: 424, y: 594), control2: CGPoint(x: 410, y: 589))
                context.closePath(); context.fillPath()
                context.restoreGState()
            }
            return true
        }
        image.isTemplate = true
        return image
    }()
}
