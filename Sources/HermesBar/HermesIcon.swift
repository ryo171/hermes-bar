import AppKit

// The menu-bar glyph. By default we draw a small vector "winged crest" mark so
// the app works with zero assets. To use the real Hermes logo instead, drop a
// black PNG named `hermes-menubar.png` (about 36x36, transparent background)
// next to the app / in ~/.hermes/ and it will be picked up automatically.
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

        // 2) Otherwise draw a vector mark.
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath()
            let w = rect.width, h = rect.height
            // Central caduceus-ish staff
            path.move(to: NSPoint(x: w * 0.5, y: h * 0.10))
            path.line(to: NSPoint(x: w * 0.5, y: h * 0.78))
            path.lineWidth = 1.4
            NSColor.black.setStroke()
            path.stroke()

            // Two wings near the top
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

            // A small orb at the top of the staff
            let orb = NSBezierPath(ovalIn: NSRect(x: w * 0.5 - 2, y: h * 0.80, width: 4, height: 4))
            orb.fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
