import AppKit

/// Explicit developer test only: an opaque own-app marker must be excluded from capture.
@MainActor final class CaptureProbe {
    let window: NSWindow
    let capture: LocalCaptureService
    let output: URL
    let diagnostics: Diagnostics
    let onError: (Error) -> Void
    private var marker: NSWindow?

    init(window: NSWindow, capture: LocalCaptureService, output: URL, diagnostics: Diagnostics, onError: @escaping (Error) -> Void) {
        self.window = window
        self.capture = capture
        self.output = output
        self.diagnostics = diagnostics
        self.onError = onError
    }

    func start() {
        guard let screen = window.screen else { return }
        let source = capture.sourceRect
        let frame = NSRect(x: screen.frame.minX + source.minX, y: screen.frame.maxY - source.maxY,
                           width: source.width, height: source.height)
        let marker = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        marker.backgroundColor = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)
        marker.isReleasedWhenClosed = false
        marker.hasShadow = false
        marker.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        marker.orderFrontRegardless()
        self.marker = marker
        do {
            try diagnostics.writeJSON(["marker_window_number": marker.windowNumber, "marker_frame_pt": NSStringFromRect(frame)], name: "capture-marker.json")
        } catch { onError(error) }
        after(3) { [self] in
            do {
                try capture.writeLatestPNG(to: output.appendingPathComponent("capture-excluding-own-app.png"))
                try diagnostics.writeJSON(capture.snapshot(), name: "capture-marker-active.json")
            } catch { onError(error) }
            self.marker?.close()
            self.marker = nil
        }
        after(4) { [self] in window.orderOut(nil) }
        after(5) { [self] in
            do { try diagnostics.writeJSON(capture.snapshot(), name: "capture-hidden-1.json") }
            catch { onError(error) }
        }
        after(6) { [self] in
            do { try diagnostics.writeJSON(capture.snapshot(), name: "capture-hidden-2.json") }
            catch { onError(error) }
        }
    }

    private func after(_ seconds: Double, action: @escaping @MainActor () -> Void) {
        Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated { action() }
        }
    }
}
