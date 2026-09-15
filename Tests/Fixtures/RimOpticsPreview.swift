import AppKit
import LabSupport

// Preview-only host. Compile against the real FramePanel and a temporary rim variant.
@main struct RimOpticsPreview {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = PreviewDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
@MainActor private final class PreviewDelegate: NSObject, NSApplicationDelegate {
    var panel: FramePanel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.main else { NSApp.terminate(nil); return }
        let env = ProcessInfo.processInfo.environment
        do {
            let panel = try FramePanel(screen: screen)
            self.panel = panel
            panel.appearance = NSAppearance(named: env["RIM_THEME"] == "light" ? .aqua : .darkAqua)
            (panel.contentView as? FrameSurface)?.showSystemMaterial()
            panel.orderFrontRegardless()
            panel.contentView?.layoutSubtreeIfNeeded()
            let frame = panel.frame
            let info: [String: Any] = ["variant": env["RIM_VARIANT"] ?? "base",
                "rect": "\(Int(frame.minX)),\(Int(screen.frame.maxY-frame.maxY)),\(Int(frame.width)),\(Int(frame.height))",
                "scale": panel.backingScaleFactor,
                "reduce_transparency": NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency]
            try JSONSerialization.data(withJSONObject: info).write(to: URL(fileURLWithPath: env["RIM_READY"]!))
            Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { _ in NSApp.terminate(nil) }
        } catch { fputs("\(error)\n", stderr); NSApp.terminate(nil) }
    }
}
