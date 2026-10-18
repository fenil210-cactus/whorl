import AppKit

/// The Whorl mark: a ring of wedges around a hub, one lit. Drawn in code so there is no asset to ship.
enum StatusIcon {
    static func make(size: CGFloat, template: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            draw(in: rect, template: template)
            return true
        }
        image.isTemplate = template
        return image
    }

    static func draw(in rect: NSRect, template: Bool) {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = rect.width * 0.46
        let inner = rect.width * 0.20
        let count = 6
        let slice = 360.0 / CGFloat(count)
        let ink: NSColor = template ? .black : .white
        if !template {
            let plate = NSBezierPath(roundedRect: rect.insetBy(dx: rect.width * 0.02, dy: rect.width * 0.02), xRadius: rect.width * 0.23, yRadius: rect.width * 0.23)
            NSGradient(colors: [NSColor(calibratedRed: 0.47, green: 0.52, blue: 1, alpha: 1), NSColor(calibratedRed: 0.27, green: 0.31, blue: 0.9, alpha: 1)])?.draw(in: plate, angle: -90)
        }
        let gap: CGFloat = 5
        for index in 0..<count {
            let start = 90 - CGFloat(index) * slice - gap / 2 + slice / 2
            let end = start - slice + gap
            let path = NSBezierPath()
            path.move(to: point(center, inner, start))
            path.appendArc(withCenter: center, radius: outer, startAngle: start, endAngle: end, clockwise: true)
            path.appendArc(withCenter: center, radius: inner, startAngle: end, endAngle: start, clockwise: false)
            path.close()
            path.lineJoinStyle = .round
            path.lineWidth = rect.width * 0.035
            ink.withAlphaComponent(index == 0 ? 1 : (template ? 0.55 : 0.62)).setFill()
            ink.withAlphaComponent(index == 0 ? 1 : (template ? 0.55 : 0.62)).setStroke()
            path.fill()
            path.stroke()
        }
    }

    private static func point(_ center: CGPoint, _ radius: CGFloat, _ degrees: CGFloat) -> CGPoint {
        let radians = degrees * .pi / 180
        return CGPoint(x: center.x + cos(radians) * radius, y: center.y + sin(radians) * radius)
    }

    static func writePNG(size: Int, to url: URL) throws {
        let image = make(size: CGFloat(size), template: false)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        try rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
