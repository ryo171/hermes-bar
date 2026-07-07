import AppKit

enum Screenshot {
    static func captureBase64PNG(maxPx: Int = 0) -> String? {
        let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("hermes_shot.png")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", tmp]
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }
        guard task.terminationStatus == 0,
              let data = try? Data(contentsOf: URL(fileURLWithPath: tmp))
        else { return nil }

        guard maxPx > 0, let src = NSBitmapImageRep(data: data) else {
            return data.base64EncodedString()
        }
        let pw = src.pixelsWide, ph = src.pixelsHigh
        let maxDim = max(pw, ph)
        guard maxDim > maxPx else { return data.base64EncodedString() }

        let scale = Double(maxPx) / Double(maxDim)
        let nw = max(1, Int(Double(pw) * scale))
        let nh = max(1, Int(Double(ph) * scale))

        guard let dst = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: nw, pixelsHigh: nh,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return data.base64EncodedString() }

        dst.size = NSSize(width: nw, height: nh)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: dst)
        src.draw(in: NSRect(x: 0, y: 0, width: nw, height: nh))
        NSGraphicsContext.restoreGraphicsState()

        guard let out = dst.representation(using: .png, properties: [:]) else {
            return data.base64EncodedString()
        }
        return out.base64EncodedString()
    }
}
