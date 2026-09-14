import AppKit
import LabSupport

/// Finite, explicitly selected integration fixture. Injection is recorded as such.
@MainActor final class CompatibilityProbe {
    private let window: NSWindow
    private let runtime: RealtimeGlassController
    private let diagnostics: Diagnostics
    private let denied: Bool
    private let requestSize: (FramePixelSize, Double) -> Void
    private let onError: (Error) -> Void
    private var timers: [Timer] = []

    init(window: NSWindow, runtime: RealtimeGlassController, diagnostics: Diagnostics, denied: Bool,
         requestSize: @escaping (FramePixelSize, Double) -> Void, onError: @escaping (Error) -> Void) {
        self.window = window; self.runtime = runtime; self.diagnostics = diagnostics
        self.denied = denied; self.requestSize = requestSize; self.onError = onError
    }

    func start() {
        after(2) { self.record("initial") }
        after(3) { if !self.denied { self.runtime.capture.overrideStatusForTesting("blank") } }
        after(3.5) { self.record("unavailable") }
        after(4) { self.requestSize(FramePixelSize(width: 1200, height: 180), 0.3) }
        after(5) { self.dragBy(dx: 60, dy: -20); self.record("drag_requested") }
        after(5.8) { self.record("fallback_geometry") }
        after(6) { self.runtime.capture.overrideStatusForTesting(nil) }
        after(7) { self.record("recovered_blank") }
        after(8) { if !self.denied { self.runtime.capture.overrideStatusForTesting("suspended") } }
        after(9) { self.record("suspended") }
        after(10) { self.runtime.capture.overrideStatusForTesting(nil) }
        after(11) { self.record("recovered_suspended") }
        after(12) { if !self.denied { self.runtime.capture.overrideStatusForTesting("stopped") } }
        after(13) { self.record("stopped") }
        after(14) { self.runtime.capture.overrideStatusForTesting(nil) }
        after(15) { self.record("recovered_stopped") }
        after(16) { if !self.denied { Task { await self.runtime.capture.interruptForTesting() } } }
        after(17) { self.record("stream_failed") }
        after(18) { if !self.denied { self.runtime.restartCapture() } }
        after(19.5) { self.record("recovered_stream") }
        after(20) { if !self.denied { self.runtime.capture.requestRebindForTesting() } }
        after(22) { self.record("recovered_rebind") }
        after(23) { self.window.orderOut(nil) }
        after(24) { self.record("hidden") }
        after(25) { self.window.orderFrontRegardless() }
        after(25.8) { if !self.denied { self.runtime.delayNextGeometryPresentationForTesting() } }
        after(26) { self.requestSize(.minimum, 0.3) }
        after(27) { self.record("final") }
        after(28) { self.closeThroughContextMenu() }
    }

    private func dragBy(dx: Double, dy: Double) {
        guard let surface = window.contentView as? FrameSurface else { return }
        let point = NSPoint(x: window.glassRectInWindow.midX, y: window.glassRectInWindow.midY)
        func event(_ type: NSEvent.EventType, _ location: NSPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                              timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                              context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        if let down = event(.leftMouseDown, point) { surface.mouseDown(with: down) }
        let moved = NSPoint(x: point.x+dx, y: point.y+dy)
        if let drag = event(.leftMouseDragged, moved) { surface.mouseDragged(with: drag) }
        if let up = event(.leftMouseUp, moved) { surface.mouseUp(with: up) }
    }

    private func closeThroughContextMenu() {
        guard let surface = window.contentView as? FrameSurface,
              let event = NSEvent.mouseEvent(with: .rightMouseDown, location: window.glassRectInWindow.origin,
                  modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                  context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
              let menu = surface.menu(for: event), menu.numberOfItems == 1, menu.item(at: 0)?.title == "关闭" else {
            onError(OptionError.invalid("Fallback context menu unavailable")); return
        }
        record("context_menu_close")
        menu.performActionForItem(at: 0)
    }

    private func record(_ stage: String) {
        do {
            var data = runtime.snapshot()
            data["probe_stage"] = stage
            data["probe_injection"] = denied ? "permission_denial" : "frame_status_and_stream_interruption"
            data["frame_pt"] = NSStringFromRect(window.frame)
            data["window_number"] = window.windowNumber
            data["window_visible"] = window.isVisible
            data["resident_bytes"] = Diagnostics.residentBytes()
            try diagnostics.writeJSON(data, name: "compat-\(stage).json")
        } catch { onError(error) }
    }

    private func after(_ delay: Double, _ action: @escaping @MainActor () -> Void) {
        timers.append(Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated { action() }
        })
    }
    deinit { timers.forEach { $0.invalidate() } }
}
