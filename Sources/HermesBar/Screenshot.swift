import AppKit

// Captures the whole screen silently using the system `screencapture` tool and
// returns a base64-encoded PNG. Requires Screen Recording permission the first
// time (macOS will prompt).
enum Screenshot {
    static func captureBase64PNG() -> String? {
        let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("hermes_shot.png")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", tmp]   // -x = no shutter sound
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }
        guard task.terminationStatus == 0,
              let data = try? Data(contentsOf: URL(fileURLWithPath: tmp))
        else { return nil }
        return data.base64EncodedString()
    }
}
