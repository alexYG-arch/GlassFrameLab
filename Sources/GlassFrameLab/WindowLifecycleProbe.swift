import AppKit

/// Explicit development fixture. Never used by the default frame UI.
final class WindowLifecycleProbe {
    private let frame: NSWindow
    private let background: NSWindow
    private let diagnostics: Diagnostics
    private let onError: (Error) -> Void

    init(frame: NSWindow, diagnostics: Diagnostics, onError: @escaping (Error) -> Void) {
        self.frame = frame
        self.diagnostics = diagnostics
        self.onError = onError
        background = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        background.title = "GlassFrame lifecycle fixture"
        background.isReleasedWhenClosed = false
        background.collectionBehavior = [.fullScreenPrimary]
        background.contentView = CalibrationView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
        background.center()
    }

    func start() {
        background.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        after(1) { self.record("normal") }
        after(2) { self.frame.orderOut(nil); self.record("hidden") }
        after(3) {
            self.frame.setFrameOrigin(NSPoint(x: self.frame.frame.minX + 24, y: self.frame.frame.minY))
            self.frame.orderFrontRegardless()
            self.record("reshown")
        }
        after(4) { self.background.toggleFullScreen(nil) }
        after(8) { self.record("fullscreen") }
        after(11) { self.background.toggleFullScreen(nil) }
        after(15) { self.record("restored"); self.background.close() }
    }

    private func after(_ seconds: Double, action: @escaping () -> Void) {
        Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in action() }
    }

    private func record(_ stage: String) {
        do {
            try diagnostics.writeJSON([
                "stage": stage,
                "frame_window_id": frame.windowNumber,
                "frame_visible": frame.isVisible,
                "frame_on_active_space": frame.isOnActiveSpace,
                "frame_rect_pt": NSStringFromRect(frame.frame),
                "fixture_fullscreen": background.styleMask.contains(.fullScreen),
                "frontmost_application": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
            ], name: "window-probe-\(stage).json")
        } catch { onError(error) }
    }
}
