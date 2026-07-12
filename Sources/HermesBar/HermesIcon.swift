import AppKit

// The menu-bar glyph. Four selectable vector styles (set in Settings), so the
// app works with zero assets. To use a real logo instead, drop a black PNG named
// `hermes-menubar.png` (about 36x36, transparent) next to the app / in ~/.hermes/
// and it will be picked up automatically, overriding the vector style.
enum IconStyle: String, CaseIterable {
    case winged, spark, comet, prompt, hermes
    var label: String {
        switch self {
        case .winged: return "Winged mark"
        case .spark:  return "Spark panel"
        case .comet:  return "Comet caret"
        case .prompt: return "Prompt spark"
        case .hermes: return "Hermes"
        }
    }
}

enum HermesIcon {
    // A user-chosen custom icon at ~/.hermes/hermes-menubar.png overrides the
    // built-in styles at runtime. The shipped "Hermes" style loads a bundled
    // image (hermes-girl.png) so it survives rebuilds and can't be deleted.
    static var customImagePath: String {
        (Settings.hermesDir as NSString).appendingPathComponent("hermes-menubar.png")
    }
    static func hasCustomImage() -> Bool { FileManager.default.fileExists(atPath: customImagePath) }
    static func removeCustomImage() { try? FileManager.default.removeItem(atPath: customImagePath) }

    static func loadCustomPreview() -> NSImage? {
        guard hasCustomImage(), let img = NSImage(contentsOfFile: customImagePath) else { return nil }
        img.isTemplate = true
        return img
    }

    // Cut the background out of a picked image and flatten to a black template
    // (adapts to light/dark). Detects the background from the four corners, so it
    // works for a subject on a plain background of any colour, or transparency.
    @discardableResult
    static func installCustomImage(from url: URL) -> Bool {
        guard let src = NSImage(contentsOf: url) else { return false }
        let os = src.size
        guard os.width > 0, os.height > 0 else { return false }
        let maxDim: CGFloat = 128
        let scale = min(1.0, maxDim / max(os.width, os.height))
        let w = max(1, Int((os.width * scale).rounded()))
        let h = max(1, Int((os.height * scale).rounded()))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: w * 4, bitsPerPixel: 32) else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        src.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()

        func rgba(_ x: Int, _ y: Int) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
            let c = (rep.colorAt(x: x, y: y) ?? .clear).usingColorSpace(.deviceRGB) ?? .clear
            return (c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
        }
        let corners = [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)].map { rgba($0.0, $0.1) }
        let bgR = corners.map { $0.0 }.reduce(0, +) / 4
        let bgG = corners.map { $0.1 }.reduce(0, +) / 4
        let bgB = corners.map { $0.2 }.reduce(0, +) / 4
        let bgA = corners.map { $0.3 }.reduce(0, +) / 4
        let transparentBackground = bgA < 0.3

        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: w * 4, bitsPerPixel: 32) else { return false }
        for y in 0..<h {
            for x in 0..<w {
                let (r, g, b, sa) = rgba(x, y)
                var a: CGFloat
                if transparentBackground {
                    a = sa
                } else {
                    let d = ((r - bgR) * (r - bgR) + (g - bgG) * (g - bgG) + (b - bgB) * (b - bgB)).squareRoot()
                    a = min(1, max(0, (d - 0.10) / 0.30)) * sa
                }
                out.setColor(NSColor(red: 0, green: 0, blue: 0, alpha: a), atX: x, y: y)
            }
        }
        guard let png = out.representation(using: .png, properties: [:]) else { return false }
        try? FileManager.default.createDirectory(atPath: Settings.hermesDir, withIntermediateDirectories: true)
        do { try png.write(to: URL(fileURLWithPath: customImagePath)); return true }
        catch { return false }
    }

    // Look up a bundled PNG resource by name.
    private static func bundledImage(_ name: String) -> NSImage? {
        guard let base = Bundle.main.resourcePath else { return nil }
        let p = (base as NSString).appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: p) else { return nil }
        return NSImage(contentsOfFile: p)
    }

    static func statusBarImage() -> NSImage {
        // 1) A runtime custom logo (~/.hermes or bundle) wins over everything.
        let candidates = [
            customImagePath,
            (Bundle.main.resourcePath.map { ($0 as NSString).appendingPathComponent("hermes-menubar.png") }) ?? ""
        ]
        for path in candidates where !path.isEmpty {
            if FileManager.default.fileExists(atPath: path), let img = NSImage(contentsOfFile: path) {
                img.size = NSSize(width: 18, height: 18)
                img.isTemplate = true
                return img
            }
        }

        // 2) The shipped "Hermes" style loads its bundled image asset.
        let style = IconStyle(rawValue: Settings.shared.iconStyle) ?? .winged
        if style == .hermes, let img = bundledImage("hermes-girl.png") {
            img.size = NSSize(width: 18, height: 18)
            img.isTemplate = true
            return img
        }

        // 3) Otherwise draw the selected vector style.
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            switch style {
            case .winged, .hermes: drawWinged(rect)   // .hermes falls back if the asset is missing
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
