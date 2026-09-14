import AppKit
import CoreGraphics

/// Public, read-only signals. No private session keys or lock-screen interactions.
@MainActor enum DesktopAvailability {
    static func blockers(for screen: NSScreen?) -> Set<String> {
        var result: Set<String> = []
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.loginwindow" {
            result.insert("login_window")
        }
        if let screen,
           let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value {
            if CGDisplayIsAsleep(id) != 0 { result.insert("display_asleep") }
        } else { result.insert("display_unavailable") }
        return result
    }
}
