import AppKit
import WhorlCore

extension Wedge {
    var symbol: String? {
        switch self {
        case .convert: return nil
        case .tool(let tool):
            switch tool {
            case .compress: return "arrow.down.right.and.arrow.up.left"
            case .rotate: return "rotate.right"
            case .metadata: return "location.slash"
            case .split: return "rectangle.split.2x1"
            case .merge: return "square.on.square"
            }
        case .action(let action):
            switch action {
            case .airdrop: return "dot.radiowaves.left.and.right"
            case .float: return "pip"
            case .copy: return "doc.on.doc"
            case .move: return "folder"
            case .copyPath: return "link"
            case .terminal: return "terminal"
            }
        }
    }
}

enum WheelArt {
    /// `glass` means the ring sits on a blurred NSVisualEffectView, so no opaque backdrop is drawn.
    static func draw(wedges: [Wedge], highlighted: Int?, mode: WheelMode, caption: String, summary: (symbol: String, text: String), center: CGPoint, glass: Bool = false) {
        let inner = Wheel.innerRadius
        let outer = Wheel.outerRadius
        let accent = AppInfo.accent

        if !glass {
            // Soft backdrop so the ring reads on any wallpaper.
            let backdrop = NSBezierPath(ovalIn: NSRect(x: center.x - outer - 10, y: center.y - outer - 10, width: (outer + 10) * 2, height: (outer + 10) * 2))
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 24
            shadow.shadowOffset = NSSize(width: 0, height: -6)
            shadow.shadowColor = NSColor(white: 0, alpha: 0.35)
            shadow.set()
            NSColor(white: 0.08, alpha: 0.9).setFill()
            backdrop.fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        let count = max(wedges.count, 1)
        let gap: CGFloat = 1.6
        for index in wedges.indices {
            let start = Wheel.angle(index: index, count: count) - gap
            let end = Wheel.angle(index: index + 1, count: count) + gap
            let path = NSBezierPath()
            path.move(to: point(center, inner, start))
            path.appendArc(withCenter: center, radius: outer - 4, startAngle: start, endAngle: end, clockwise: true)
            path.appendArc(withCenter: center, radius: inner, startAngle: end, endAngle: start, clockwise: false)
            path.close()
            path.lineJoinStyle = .round
            path.lineWidth = 4
            let isOn = index == highlighted
            if isOn {
                NSGraphicsContext.saveGraphicsState()
                let glow = NSShadow()
                glow.shadowBlurRadius = 14
                glow.shadowColor = accent.withAlphaComponent(0.7)
                glow.set()
                accent.setFill()
                path.fill()
                NSGraphicsContext.restoreGraphicsState()
                path.addClip()
                NSGradient(starting: accent.blended(withFraction: 0.28, of: .white) ?? accent, ending: accent)?
                    .draw(in: path.bounds, angle: -90)
                NSGraphicsContext.current?.cgContext.resetClip()
            } else {
                if glass {
                    NSColor(white: 0, alpha: 0.22).setFill()
                    path.fill()
                }
                NSColor(white: 1, alpha: glass ? 0.075 : 0.10).setFill()
                path.fill()
                NSColor(white: 1, alpha: glass ? 0.075 : 0.10).setStroke()
                path.stroke()
            }

            let middle = (start + end) / 2
            let spot = point(center, (inner + outer) / 2, middle)
            let tint = NSColor.white
            if let symbol = wedges[index].symbol, let image = symbolImage(symbol, size: 17, color: tint) {
                image.draw(at: NSPoint(x: spot.x - image.size.width / 2, y: spot.y - 2), from: .zero, operation: .sourceOver, fraction: 1)
                drawText(wedges[index].label, at: NSPoint(x: spot.x, y: spot.y - 11), size: 9.5, weight: .semibold, color: tint)
            } else {
                drawText(wedges[index].label, at: NSPoint(x: spot.x, y: spot.y), size: wedges[index].label.count > 4 ? 12 : 14, weight: .bold, color: tint)
            }
        }

        // Hub: what is being dragged.
        let hub = NSBezierPath(ovalIn: NSRect(x: center.x - inner + 8, y: center.y - inner + 8, width: (inner - 8) * 2, height: (inner - 8) * 2))
        NSColor(white: glass ? 0 : 1, alpha: glass ? 0.30 : 0.08).setFill()
        hub.fill()
        NSColor(white: 1, alpha: 0.16).setStroke()
        hub.lineWidth = 1
        hub.stroke()
        if glass {
            let rim = NSBezierPath(ovalIn: NSRect(x: center.x - outer, y: center.y - outer, width: outer * 2, height: outer * 2))
            NSColor(white: 1, alpha: 0.16).setStroke()
            rim.lineWidth = 1
            rim.stroke()
        }
        if let image = symbolImage(summary.symbol, size: 18, color: NSColor(white: 1, alpha: 0.9)) {
            image.draw(at: NSPoint(x: center.x - image.size.width / 2, y: center.y + 1), from: .zero, operation: .sourceOver, fraction: 1)
        }
        drawText(summary.text, at: NSPoint(x: center.x, y: center.y - 11), size: 11, weight: .semibold, color: .white)

        // Mode chips above the ring: the three keys and what each one opens.
        let modes = WheelMode.allCases
        let chipWidth: CGFloat = 92
        let total = chipWidth * CGFloat(modes.count) + 6 * CGFloat(modes.count - 1)
        var x = center.x - total / 2
        let chipY = center.y + outer + 22
        for item in modes {
            let rect = NSRect(x: x, y: chipY, width: chipWidth, height: 22)
            let active = item == mode
            let pill = NSBezierPath(roundedRect: rect, xRadius: 11, yRadius: 11)
            (active ? accent : NSColor(white: 0.06, alpha: glass ? 0.55 : 0.85)).setFill()
            pill.fill()
            drawText("\(Prefs.key(for: item).symbol)  \(item.title)", at: NSPoint(x: rect.midX, y: rect.midY - 0.5), size: 11, weight: active ? .semibold : .medium, color: NSColor(white: 1, alpha: active ? 1 : 0.7))
            x += chipWidth + 6
        }

        // Caption below.
        let captionRect = textSize(caption, size: 12, weight: .medium)
        let pillRect = NSRect(x: center.x - captionRect.width / 2 - 14, y: center.y - outer - 46, width: captionRect.width + 28, height: 26)
        NSColor(white: 0.06, alpha: glass ? 0.6 : 0.88).setFill()
        NSBezierPath(roundedRect: pillRect, xRadius: 13, yRadius: 13).fill()
        drawText(caption, at: NSPoint(x: pillRect.midX, y: pillRect.midY - 0.5), size: 12, weight: .medium, color: .white)
    }

    private static func point(_ center: CGPoint, _ radius: CGFloat, _ degrees: CGFloat) -> CGPoint {
        let radians = degrees * .pi / 180
        return CGPoint(x: center.x + cos(radians) * radius, y: center.y + sin(radians) * radius)
    }

    private static func attributes(_ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
    }

    private static func textSize(_ text: String, size: CGFloat, weight: NSFont.Weight) -> NSSize {
        NSString(string: text).size(withAttributes: attributes(size, weight, .white))
    }

    /// Draws `text` centred on `point`.
    private static func drawText(_ text: String, at point: NSPoint, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
        let string = NSString(string: text)
        let attrs = attributes(size, weight, color)
        let box = string.size(withAttributes: attrs)
        string.draw(at: NSPoint(x: point.x - box.width / 2, y: point.y - box.height / 2), withAttributes: attrs)
    }

    static func symbolImage(_ name: String, size: CGFloat, color: NSColor) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)) else { return nil }
        let image = NSImage(size: base.size)
        image.lockFocus()
        base.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        color.set()
        NSRect(origin: .zero, size: base.size).fill(using: .sourceAtop)
        image.unlockFocus()
        return image
    }
}
