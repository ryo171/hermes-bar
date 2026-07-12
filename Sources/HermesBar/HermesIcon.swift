import AppKit

// The menu-bar glyph. Four selectable vector styles (set in Settings), so the
// app works with zero assets. To use a real logo instead, drop a black PNG named
// `hermes-menubar.png` (about 36x36, transparent) next to the app / in ~/.hermes/
// and it will be picked up automatically, overriding the vector style.
enum IconStyle: String, CaseIterable {
    case winged, spark, comet, prompt
    var label: String {
        switch self {
        case .winged: return "Winged mark"
        case .spark:  return "Spark panel"
        case .comet:  return "Comet caret"
        case .prompt: return "Prompt spark"
        }
    }
}

enum HermesIcon {
    static func statusBarImage() -> NSImage {
        // 1) Prefer a user-supplied logo if present.
        let candidates = [
            (Settings.hermesDir as NSString).appendingPathComponent("hermes-menubar.png"),
            (Bundle.main.resourcePath.map { ($0 as NSString).appendingPathComponent("hermes-menubar.png") }) ?? ""
        ]
        for path in candidates where !path.isEmpty {
            if FileManager.default.fileExists(atPath: path), let img = NSImage(contentsOfFile: path) {
                img.size = NSSize(width: 18, height: 18)
                img.isTemplate = true
                return img
            }
        }

        // 2) Otherwise draw the selected vector style.
        let style = IconStyle(rawValue: Settings.shared.iconStyle) ?? .winged
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            switch style {
            case .winged: drawWinged(rect)
            case .spark:  drawSpark(rect)
            case .comet:  drawComet(rect)
            case .prompt: drawPrompt(rect)
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - Styles

    private static func drawWinged(_ rect: NSRect) {
        let w = rect.width, h = rect.height
        let staff = NSBezierPath()
        staff.move(to: NSPoint(x: w * 0.5, y: h * 0.10))
        staff.line(to: NSPoint(x: w * 0.5, y: h * 0.78))
        staff.lineWidth = 1.4
        staff.stroke()

        let leftWing = NSBezierPath()
        leftWing.move(to: NSPoint(x: w * 0.5, y: h * 0.72))
        leftWing.curve(to: NSPoint(x: w * 0.16, y: h * 0.86),
                       controlPoint1: NSPoint(x: w * 0.36, y: h * 0.74),
                       controlPoint2: NSPoint(x: w * 0.22, y: h * 0.80))
        leftWing.curve(to: NSPoint(x: w * 0.5, y: h * 0.80),
                       controlPoint1: NSPoint(x: w * 0.30, y: h * 0.84),
                       controlPoint2: NSPoint(x: w * 0.40, y: h * 0.82))
        leftWing.fill()

        let rightWing = NSBezierPath()
        rightWing.move(to: NSPoint(x: w * 0.5, y: h * 0.72))
        rightWing.curve(to: NSPoint(x: w * 0.84, y: h * 0.86),
                        controlPoint1: NSPoint(x: w * 0.64, y: h * 0.74),
                        controlPoint2: NSPoint(x: w * 0.78, y: h * 0.80))
        rightWing.curve(to: NSPoint(x: w * 0.5, y: h * 0.80),
                        controlPoint1: NSPoint(x: w * 0.70, y: h * 0.84),
                        controlPoint2: NSPoint(x: w * 0.60, y: h * 0.82))
        rightWing.fill()

        NSBezierPath(ovalIn: NSRect(x: w * 0.5 - 2, y: h * 0.80, width: 4, height: 4)).fill()
    }

    private static func drawSpark(_ rect: NSRect) {
        let w = rect.width, h = rect.height
        // Mini panel outline.
        let panel = NSBezierPath(roundedRect: NSRect(x: w * 0.16, y: h * 0.20, width: w * 0.56, height: h * 0.48),
                                 xRadius: 3, yRadius: 3)
        panel.lineWidth = 1.4
        panel.stroke()
        // Four-point spark at the top-right.
        let cx = w * 0.78, cy = h * 0.74, r = w * 0.16
        let star = NSBezierPath()
        star.move(to: NSPoint(x: cx, y: cy + r))
        star.line(to: NSPoint(x: cx + r * 0.28, y: cy + r * 0.28))
        star.line(to: NSPoint(x: cx + r, y: cy))
        star.line(to: NSPoint(x: cx + r * 0.28, y: cy - r * 0.28))
        star.line(to: NSPoint(x: cx, y: cy - r))
        star.line(to: NSPoint(x: cx - r * 0.28, y: cy - r * 0.28))
        star.line(to: NSPoint(x: cx - r, y: cy))
        star.line(to: NSPoint(x: cx - r * 0.28, y: cy + r * 0.28))
        star.close()
        star.fill()
    }

    private static func drawComet(_ rect: NSRect) {
        let w = rect.width, h = rect.height
        // Head.
        NSBezierPath(ovalIn: NSRect(x: w * 0.58, y: h * 0.56, width: w * 0.22, height: w * 0.22)).fill()
        // Tail.
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: w * 0.60, y: h * 0.58))
        tail.line(to: NSPoint(x: w * 0.18, y: h * 0.20))
        tail.lineWidth = 2.0
        tail.lineCapStyle = .round
        tail.stroke()
        let tail2 = NSBezierPath()
        tail2.move(to: NSPoint(x: w * 0.72, y: h * 0.56))
        tail2.line(to: NSPoint(x: w * 0.40, y: h * 0.24))
        tail2.lineWidth = 1.3
        tail2.lineCapStyle = .round
        tail2.stroke()
    }

    private static func drawPrompt(_ rect: NSRect) {
        let w = rect.width, h = rect.height
        let chevron = NSBezierPath()
        chevron.move(to: NSPoint(x: w * 0.28, y: h * 0.76))
        chevron.line(to: NSPoint(x: w * 0.54, y: h * 0.50))
        chevron.line(to: NSPoint(x: w * 0.28, y: h * 0.24))
        chevron.lineWidth = 2.0
        chevron.lineJoinStyle = .round
        chevron.lineCapStyle = .round
        chevron.stroke()

        let underscore = NSBezierPath()
        underscore.move(to: NSPoint(x: w * 0.58, y: h * 0.22))
        underscore.line(to: NSPoint(x: w * 0.80, y: h * 0.22))
        underscore.lineWidth = 2.0
        underscore.lineCapStyle = .round
        underscore.stroke()
    }
}
