import AppKit
import LabSupport

@MainActor final class LabDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let options: LaunchOptions
    let diagnostics: Diagnostics
    var window: NSWindow?
    var exitStatus: Int32 = 0
    private var sampleTimer: Timer?
    private var animationTimer: Timer?
    private var started = ProcessInfo.processInfo.systemUptime
    private var lifecycleProbe: WindowLifecycleProbe?
    private var geometryController: WindowGeometryController?
    private var captureService: LocalCaptureService?
    private var captureProbe: CaptureProbe?
    private var glassRenderer: GlassRenderer?
    private var realtimeController: RealtimeGlassController?
    private var compatibilityProbe: CompatibilityProbe?
    private var upgradeObservations: [[String: Any]] = []
    private var permissionNoticeShown = false

    init(options: LaunchOptions) throws {
        self.options = options
        diagnostics = try Diagnostics(output: options.output)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            installMenu()
            let mode = options.baseline ? "baseline_no_window" : (options.calibration ? (options.animate ? "animated_test_window" : "static_test_window") : (options.realtime ? "realtime_glass" : "frame_carrier"))
            try diagnostics.writeJSON(Diagnostics.environment(mode: mode), name: "environment.json")
            if let output = options.output { try JSONEncoder().encode(options.style).write(to: output.appendingPathComponent("style.json"), options: .atomic) }
            if !options.baseline {
                if options.calibration { showTestWindow() }
                else { try showFrame() }
            }
            try diagnostics.writeJSON([
                "event": "application_ready", "mode": mode,
                "measurement_start_uptime": diagnostics.start,
                "window_number": window?.windowNumber ?? -1,
                "content_size_pt": window.map { NSStringFromSize($0.glassFrame.size) } ?? "none",
                "backing_scale": window?.backingScaleFactor ?? 0,
                "content_size_px": window.map { NSStringFromSize(NSSize(width: $0.glassFrame.width * $0.backingScaleFactor, height: $0.glassFrame.height * $0.backingScaleFactor)) } ?? "none",
                "frame_pt": window.map { NSStringFromRect($0.frame) } ?? "none",
                "panel_size_px": window.map { NSStringFromSize($0.convertToBacking($0.contentLayoutRect).size) } ?? "none",
                "glass_frame_pt": window.map { NSStringFromRect($0.glassFrame) } ?? "none",
                "screen_capture_enabled": false,
                "capture_requested": options.captureProbe || options.glassPreview || options.realtime
            ], name: "ready.json")
            sampleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                // This timer is installed on the application's main run loop.
                MainActor.assumeIsolated {
                guard let self else { return }
                do { try self.diagnostics.sample(windowVisible: self.window?.isVisible == true) }
                catch { self.fail(error) }
                if let captureService = self.captureService {
                    do { try self.diagnostics.writeJSON(captureService.snapshot(), name: "capture-latest.json") }
                    catch { self.fail(error) }
                }
                if let runtime = self.realtimeController {
                    runtime.tick()
                    if runtime.capture.state == "permission_required", self.options.permissionPrompt,
                       !self.options.forcePermissionDenied, !self.permissionNoticeShown {
                        self.permissionNoticeShown = true
                        DispatchQueue.main.async { [weak self] in self?.explainScreenAccess() }
                    }
                    do {
                        try self.diagnostics.recordFrames(runtime.renderer.metrics.drain())
                        try self.diagnostics.recordRuntime(runtime.snapshot())
                        try self.diagnostics.writeJSON(runtime.snapshot(), name: "runtime-latest.json")
                    } catch { self.fail(error) }
                }
                }
            }
            if let duration = options.duration {
                Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { _ in NSApp.terminate(nil) }
            }
            print("READY mode=\(mode) window=\(window?.windowNumber ?? -1)")
            fflush(stdout)
            if options.windowProbe, let window {
                lifecycleProbe = WindowLifecycleProbe(frame: window, diagnostics: diagnostics) { [weak self] error in self?.fail(error) }
                lifecycleProbe?.start()
            }
            if options.geometryProbe { startGeometryProbe() }
            if options.realtime, let window {
                do {
                    if options.forceMetalUnavailable { throw OptionError.invalid("Injected Metal initialization failure") }
                    let runtime = try RealtimeGlassController(window: window, style: options.style, adaptive: options.adaptiveMaterial, borderFlow: options.borderFlow, forceAccessDenied: options.forcePermissionDenied) { [weak self] error in
                        guard let self else { return }
                        do { try self.diagnostics.writeJSON(["error": String(describing: error)], name: "runtime-error.json") }
                        catch { self.fail(error) }
                    }
                    realtimeController = runtime
                    if let surface = window.contentView as? FrameSurface {
                        surface.dragActivity = { [weak runtime] active in runtime?.setFlowMotion("drag", active: active) }
                        surface.flowEnabled = { [weak runtime] in runtime?.borderFlow.enabled ?? false }
                        surface.materialStatus = { [weak runtime] in runtime?.materialStatus ?? "实时材质未启动" }
                        surface.reconnectMaterial = { [weak self] in self?.reconnectBackground() }
                        surface.flowToggle = { [weak self, weak runtime] in
                            guard let runtime else { return }
                            var flow = runtime.borderFlow; flow.enabled.toggle()
                            do { try runtime.applyBorderFlow(flow) } catch { self?.fail(error) }
                        }
                    }
                    captureService = runtime.capture
                    Task { @MainActor in await runtime.start() }
                    if options.upgradeProbe { startUpgradeProbe() }
                    if options.runtimeProbe { startRuntimeProbe() }
                    if options.styleProbe { startStyleProbe() }
                    if options.motionProbe { startMotionProbe() }
                    if options.motionPerformance { startMotionPerformance() }
                    if options.compatibilityProbe {
                        let probe = CompatibilityProbe(window: window, runtime: runtime, diagnostics: diagnostics,
                            denied: options.forcePermissionDenied, requestSize: { [weak self] size, duration in
                                self?.geometryController?.request(size, duration: duration)
                            }, onError: { [weak self] in self?.fail($0) })
                        compatibilityProbe = probe
                        probe.start()
                    }
                } catch {
                    if let surface = window.contentView as? FrameSurface {
                        surface.carrierVisible = false
                        surface.showFallback(true)
                        surface.materialStatus = { "替代材质：图形渲染未启动，流光不可用" }
                        let reason = String(describing: error)
                        surface.reconnectMaterial = {
                            let alert = NSAlert()
                            alert.messageText = "实时材质未启动"
                            alert.informativeText = "图形渲染初始化失败，请重新启动应用。\n" + reason
                            alert.runModal()
                        }
                    }
                    try diagnostics.writeJSON(["error": String(describing: error), "state": "native_fallback",
                        "fallback_visible": (window.contentView as? FrameSurface)?.fallbackActive ?? false,
                        "injected_metal_failure": options.forceMetalUnavailable], name: "runtime-error.json")
                }
            }
            if options.captureProbe || options.glassPreview, let window {
                let capture = LocalCaptureService(sigma: options.sigma)
                captureService = capture
                NotificationCenter.default.addObserver(self, selector: #selector(stopCaptureWhenHidden), name: NSApplication.didHideNotification, object: NSApp)
                Task { @MainActor in
                    await capture.start(for: window)
                    do { try self.diagnostics.writeJSON(capture.snapshot(), name: "capture-start.json") }
                    catch { self.fail(error) }
                    if self.options.glassPreview, capture.state == "capturing" {
                        do { try await self.showGlassPreview(capture: capture, window: window) }
                        catch {
                            self.glassRenderer?.view.removeFromSuperview()
                            self.glassRenderer = nil
                            window.contentView?.subviews.filter { $0 is ForegroundProbeView }.forEach { $0.removeFromSuperview() }
                            await capture.stop()
                            do { try self.diagnostics.writeJSON(["state": "frame_carrier", "error": String(describing: error)], name: "glass-error.json") }
                            catch { self.fail(error) }
                        }
                    } else if self.options.captureProbe, capture.state == "capturing", !self.options.geometryProbe, let output = self.options.output {
                        self.captureProbe = CaptureProbe(window: window, capture: capture, output: output, diagnostics: self.diagnostics) { [weak self] error in self?.fail(error) }
                        self.captureProbe?.start()
                    }
                }
            }
        } catch {
            fail(error)
        }
    }

    private func explainScreenAccess() {
        guard window?.isVisible == true, captureService?.state == "permission_required" else { return }
        let alert = NSAlert()
        alert.messageText = "实时毛玻璃需要读取框体后方的画面"
        alert.informativeText = "目前显示的是替代材质，深色适配和流光尚未运行。请在系统的屏幕录制权限中允许 GlassFrame Lab。仅在本机处理背景，不录制音频或保存录像。授权后会尝试自动恢复；若系统要求，请退出并重新打开应用。"
        alert.addButton(withTitle: "前往授权")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { reconnectBackground() }
    }

    private func reconnectBackground() {
        guard !options.forcePermissionDenied else { return }
        if CGPreflightScreenCaptureAccess() {
            realtimeController?.restartCapture()
        } else {
            permissionNoticeShown = true
            if CGRequestScreenCaptureAccess() {
                realtimeController?.restartCapture()
            } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func showGlassPreview(capture: LocalCaptureService, window: NSWindow) async throws {
        for _ in 0..<30 {
            if capture.latestBuffer() != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard window.isVisible else { return }
        guard let buffer = capture.latestBuffer(), let screen = window.screen, let surface = window.contentView else {
            throw OptionError.invalid("No visible window or complete local frame for glass preview")
        }
        let renderer = try GlassRenderer(frame: surface.bounds, style: options.style, adaptive: options.adaptiveMaterial)
        glassRenderer = renderer
        surface.addSubview(renderer.view)
        (surface as? FrameSurface)?.carrierVisible = false
        if options.foregroundProbe {
            surface.addSubview(ForegroundProbeView(frame: NSRect(x: 16, y: 13, width: 94, height: 24)))
        }
        if let output = options.output {
            try capture.writePNG(buffer: buffer, to: output.appendingPathComponent("capture-input.png"))
        }
        var result = try await renderer.render(buffer: buffer, glassFrame: window.glassFrame, displayFrame: screen.frame,
                                               sourceRect: capture.sourceRect, scale: screen.backingScaleFactor, flow: options.borderFlow, flowPhase: options.flowPhase)
        result["sigma_sampling_pixels"] = options.sigma
        result["foreground_probe"] = options.foregroundProbe
        if options.sigma > 0, let output = options.output { try renderer.writeBlurPNG(to: output.appendingPathComponent("blur-intermediate.png")) }
        try diagnostics.writeJSON(result, name: "glass-render.json")
        await capture.stop() // WP-04 is a single-frame preview; no ongoing capture/render loop.
        try diagnostics.writeJSON(capture.snapshot(), name: "capture-stop.json")
    }

    private func showFrame() throws {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            throw OptionError.invalid("No display available for frame")
        }
        let panel = try FramePanel(screen: screen, style: options.style)
        if options.testCorner {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX + 100 - panel.shadowInset,
                                        y: screen.visibleFrame.maxY - panel.frame.height - 160 + panel.shadowInset))
        }
        panel.delegate = self
        window = panel
        geometryController = WindowGeometryController(window: panel,
            requested: FramePixelSize(width: options.widthPixels, height: options.heightPixels),
            onCommit: { [weak self] result, count in
                guard let self else { return }
                if let runtime = self.realtimeController { runtime.updateGeometry() }
                else if let window = self.window { self.captureService?.requestGeometryUpdate(for: window) }
                do {
                    try self.diagnostics.writeJSON([
                        "frame_pt": NSStringFromRect(result.frame),
                        "glass_frame_pt": NSStringFromRect(result.glassFrame),
                        "actual_size_px": NSStringFromSize(result.actualPixels),
                        "size_limited": result.sizeLimited, "used_default_input": result.usedDefaultInput,
                        "elapsed_seconds": ProcessInfo.processInfo.systemUptime - self.diagnostics.start,
                        "commit_count": count
                    ], name: self.options.upgradeProbe ? "geometry-latest.json" : String(format: "geometry-%03d.json", count))
                } catch { self.fail(error) }
            }, onError: { [weak self] error in self?.fail(error) }, beginTransition: { [weak self] in
                self?.realtimeController?.setFlowMotion("transition", active: true)
            }, prepareTransition: { [weak self] envelope, screen in
                guard let runtime = self?.realtimeController else { return true }
                return await runtime.prepareTransition(envelope: envelope, screen: screen)
            }, finishTransition: { [weak self] in self?.realtimeController?.finishTransition() },
            stageGeometry: { [weak self] result, screen, apply, completion in
                if let runtime = self?.realtimeController { runtime.stageGeometry(result.frame, screen: screen, apply: apply, completion: completion) }
                else { apply(); completion(true) }
            })
        (panel.contentView as? FrameSurface)?.requestOrigin = { [weak self] point in self?.geometryController?.move(to: point) }
        if options.realtime {
            (panel.contentView as? FrameSurface)?.carrierVisible = false
            (panel.contentView as? FrameSurface)?.showFallback(true)
        }
        panel.orderFrontRegardless()
    }

    // Short resource samples plus actual surface/menu integration actions.
    // Background/visual coverage is exercised separately; this is not acceptance.
    private func startUpgradeProbe() {
        guard let runtime = realtimeController, let window, let surface = window.contentView as? FrameSurface else { return }
        var off = runtime.borderFlow; off.enabled = false
        do { try runtime.applyBorderFlow(off) } catch { fail(error); return }
        func after(_ seconds: Double, _ action: @escaping @MainActor () -> Void) {
            Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in MainActor.assumeIsolated { action() } }
        }
        func record(_ name: String) {
            var row = runtime.snapshot()
            row["stage"] = name
            row["elapsed"] = ProcessInfo.processInfo.systemUptime - self.diagnostics.start
            row["rss"] = Diagnostics.residentBytes() ?? 0
            self.upgradeObservations.append(row)
        }
        func event(_ type: NSEvent.EventType, _ point: NSPoint = NSPoint(x: 25, y: 25)) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func menuAction(_ title: String) {
            guard let menu = surface.menu(for: event(.rightMouseDown)),
                  let item = menu.items.first(where: { $0.title == title }) else {
                self.fail(OptionError.invalid("Missing context-menu action: \(title)")); return
            }
            menu.performActionForItem(at: menu.index(of: item))
        }
        for (seconds, name) in [(5.0,"off-start"),(12,"off-end"),(16,"on-start"),(30,"on-end"),
                                (34,"light"),(39,"dark"),(41.1,"drag-start"),(42.1,"drag-end"),
                                (46.3,"resize-start"),(47.5,"resize-end"),(50,"resumed"),
                                (53,"toggled-off"),(56,"toggled-on"),(62,"hidden"),(68,"shown"),
                                (71,"once-start"),(80,"once-finished")] {
            after(seconds) { record(name) }
        }
        after(14) { menuAction("流光效果") }
        after(41) { surface.mouseDown(with: event(.leftMouseDown)) }
        after(41.25) { surface.mouseDragged(with: event(.leftMouseDragged, NSPoint(x: 70, y: 25))) }
        after(41.75) { surface.mouseDragged(with: event(.leftMouseDragged, NSPoint(x: 50, y: 45))) }
        after(42.3) { surface.mouseUp(with: event(.leftMouseUp)) }
        after(46) { self.geometryController?.request(FramePixelSize(width: 1200,height: 220), duration: 2) }
        after(52) { menuAction("流光效果") }
        after(54) { menuAction("流光效果") }
        after(60) { window.orderOut(nil); runtime.visibilityChanged() }
        after(65) { window.orderFrontRegardless(); runtime.visibilityChanged() }
        after(70) {
            var once = runtime.borderFlow; once.mode = .once
            do { try runtime.applyBorderFlow(once) } catch { self.fail(error) }
        }
        after(82) {
            record("end")
            do { try self.diagnostics.writeJSON(["scope":"source_functional_probe", "observations":self.upgradeObservations], name:"upgrade-observations.json") }
            catch { self.fail(error) }
        }
        after(83) { menuAction("关闭") }
    }

    private func startGeometryProbe() {
        let sizes = [FramePixelSize(width: 1600, height: 300), FramePixelSize(width: 10000, height: 10000), .minimum, .minimum]
        for (index, size) in sizes.enumerated() {
            Timer.scheduledTimer(withTimeInterval: Double(index + 1), repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.geometryController?.request(size) }
            }
        }
    }

    private func startRuntimeProbe() {
        func after(_ seconds: Double, _ action: @escaping @MainActor () -> Void) {
            Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in MainActor.assumeIsolated { action() } }
        }
        // Test-only local notifications exercise the production observer composition.
        // They do not put the computer to sleep or lock the user's session.
        let workspace = NSWorkspace.shared.notificationCenter
        after(8) { workspace.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil) }
        after(9) { workspace.post(name: NSWorkspace.willSleepNotification, object: nil) }
        after(10) { workspace.post(name: NSWorkspace.didWakeNotification, object: nil) }
        after(11) { [weak self] in self?.recordRuntimeProbe("runtime-nested-pause.json") }
        after(12) { workspace.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil) }
        after(14) { [weak self] in self?.recordRuntimeProbe("runtime-resumed.json") }
        after(47) { [weak self] in self?.window?.orderOut(nil) }
        after(56) { [weak self] in self?.recordRuntimeProbe("runtime-hidden-baseline.json") }
        for index in 0..<20 {
            after(Double(57 + index * 2)) { [weak self] in self?.window?.orderFrontRegardless() }
            after(Double(58 + index * 2)) { [weak self] in self?.window?.orderOut(nil) }
        }
        after(107) { [weak self] in self?.recordRuntimeProbe("runtime-hidden-final.json") }
    }

    private func startStyleProbe() {
        for index in 1...3 {
            Timer.scheduledTimer(withTimeInterval: Double(index * 3), repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let runtime = self.realtimeController else { return }
                    var style = self.options.style
                    if index == 1 { style.shadowOpacity = 0 }
                    if index == 2 { style.innerStrength = 0; style.innerShade = 0 }
                    do { try runtime.applyStyle(style) } catch { self.fail(error) }
                }
            }
        }
    }

    private func startMotionPerformance() {
        guard let window, let duration = options.duration else { return }
        let origin = window.frame.origin
        let began = ProcessInfo.processInfo.systemUptime
        var segment = -1
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0/30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let elapsed = ProcessInfo.processInfo.systemUptime-began
                guard elapsed < duration-2 else {
                    self.animationTimer?.invalidate()
                    if self.options.resizePerformance { self.geometryController?.request(.minimum, duration: 0.3) }
                    return
                }
                guard elapsed > 2, self.window?.isVisible == true else { return }
                if self.options.resizePerformance {
                    let current = Int(elapsed)
                    if current != segment {
                        segment = current
                        let size = current.isMultiple(of: 2) ? FramePixelSize(width: 1000, height: 160) : .minimum
                        self.geometryController?.request(size, duration: 1.2)
                    }
                    return
                }
                // Ordinary continuous dragging within a local ROI; same entry point as mouseDragged.
                self.geometryController?.move(to: NSPoint(x: origin.x+24*sin(elapsed*Double.pi/1.2),
                                                          y: origin.y+12*cos(elapsed*Double.pi/1.2)))
            }
        }
    }

    private func startMotionProbe() {
        func after(_ seconds: Double, _ action: @escaping @MainActor () -> Void) {
            Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in MainActor.assumeIsolated { action() } }
        }
        after(2) { [weak self] in
            guard let w = self?.window else { return }
            self?.geometryController?.move(to: NSPoint(x: w.frame.minX+80, y: w.frame.minY-20))
        }
        after(3) { [weak self] in self?.geometryController?.request(FramePixelSize(width: 1300, height: 220), duration: 0.6) }
        after(3.25) { [weak self] in self?.geometryController?.request(FramePixelSize(width: 1000, height: 160), duration: 0.35) }
        after(4.5) { [weak self] in self?.geometryController?.request(.minimum, duration: 0.3) }
        after(5.5) { [weak self] in
            guard let w = self?.window, let screen = w.screen else { return }
            self?.geometryController?.move(to: NSPoint(x: screen.visibleFrame.maxX-100, y: screen.visibleFrame.maxY-100))
        }
        after(6) { [weak self] in self?.geometryController?.request(FramePixelSize(width: 1600, height: 500), duration: 0.4) }
        after(7) { [weak self] in self?.geometryController?.request(.minimum, duration: 0.3) }
        for (time, extent, sigma) in [(8.0, 10.0, 20.0), (8.5, 6.0, 12.0)] {
            after(time) { [weak self] in
                guard let self else { return }
                var style = self.options.style; style.shadowExtent = extent; style.sigma = sigma
                do { try self.realtimeController?.applyStyle(style) } catch { self.fail(error) }
            }
        }
        // Hide during capture-envelope preparation, then issue the final visible intent.
        after(9) { [weak self] in self?.geometryController?.request(FramePixelSize(width: 1600, height: 500), duration: 0.4) }
        after(9.08) { [weak self] in self?.window?.orderOut(nil) }
        after(9.4) { [weak self] in
            self?.window?.orderFrontRegardless()
            self?.geometryController?.request(.minimum, duration: 0.3)
        }
        after(10.1) { [weak self] in self?.geometryController?.request(FramePixelSize(width: 1200, height: 180)) }
        after(10.5) { [weak self] in self?.geometryController?.request(.minimum) }
        after(11) { [weak self] in self?.recordRuntimeProbe("motion-settled.json") }
    }

    private func recordRuntimeProbe(_ name: String) {
        guard let runtime = realtimeController else { return }
        var values = runtime.snapshot()
        values["resident_bytes"] = Diagnostics.residentBytes()
        do { try diagnostics.writeJSON(values, name: name) }
        catch { fail(error) }
    }

    private func showTestWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 240),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "GlassFrame Lab — WP-00 Calibration"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let view = CalibrationView(frame: NSRect(x: 0, y: 0, width: 800, height: 240))
        view.onDraw = { [weak self] in self?.diagnostics.recordDraw() }
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        if options.animate {
            started = ProcessInfo.processInfo.systemUptime
            animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self, weak view] _ in
                MainActor.assumeIsolated {
                guard let self, let view, self.window?.isVisible == true else { return }
                view.phase = CGFloat((ProcessInfo.processInfo.systemUptime - self.started).truncatingRemainder(dividingBy: 3) / 3)
                view.needsDisplay = true
                }
            }
        }
    }

    private func installMenu() {
        let menu = NSMenu()
        let root = NSMenuItem()
        menu.addItem(root)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit GlassFrame Lab", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        root.submenu = appMenu
        NSApp.mainMenu = menu
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // AppKit excludes nonactivating panels from its ordinary-window lifecycle.
        // Product closure is handled explicitly below; hiding must not terminate.
        false
    }

    func windowWillClose(_ notification: Notification) {
        if let closing = notification.object as? NSWindow, closing === window {
            NSApp.terminate(nil)
        }
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        if let runtime = realtimeController { runtime.visibilityChanged() }
        else if window?.isVisible != true { stopCaptureWhenHidden() }
    }

    @objc private func stopCaptureWhenHidden() {
        guard let capture = captureService, capture.needsStop else { return }
        Task { @MainActor in
            await capture.stop()
            do { try self.diagnostics.writeJSON(capture.snapshot(), name: "capture-hidden.json") }
            catch { self.fail(error) }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let capture = captureService, capture.needsStop || realtimeController?.renderer.inFlight == true else { return .terminateNow }
        Task { @MainActor in
            if let runtime = self.realtimeController { await runtime.stop() }
            else { await capture.stop() }
            do { try self.diagnostics.writeJSON(capture.snapshot(), name: "capture-stop.json") }
            catch { self.exitStatus = 2; fputs("Capture stop evidence failed: \(error)\n", stderr) }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func fail(_ error: Error) {
        exitStatus = 2
        fputs("Run failed: \(error)\n", stderr)
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        animationTimer?.invalidate()
        sampleTimer?.invalidate()
        do {
            if exitStatus == 0 { try diagnostics.sample(windowVisible: window?.isVisible == true) }
            if let runtime = realtimeController { try diagnostics.recordFrames(runtime.renderer.metrics.drain()) }
            try diagnostics.finish()
        } catch {
            exitStatus = 2
            fputs("Metrics finalization failed: \(error)\n", stderr)
        }
        do {
            try diagnostics.writeJSON([
                "event": exitStatus == 0 ? "application_terminated" : "application_failed",
                "exit_status": exitStatus, "sample_count": diagnostics.sampleCount
            ], name: "termination.json")
        } catch {
            exitStatus = 2
            fputs("Termination evidence failed: \(error)\n", stderr)
        }
        // NSApplication.terminate normally exits the process itself with status 0.
        // Preserve a diagnostic failure after flushing its evidence.
        if exitStatus != 0 { exit(exitStatus) }
    }
}

if CommandLine.arguments.contains("--help") {
    print("GlassFrameLab [--frame-carrier | --baseline | --calibration | --animate | --window-probe | --geometry-probe | --capture-probe | --glass-preview | --runtime-probe] [--border-flow | --flow-once] [--flow-style FILE.json] [--flow-phase 0...1] [--no-adaptive-material] [--upgrade-probe] [--test-corner] [--style FILE.json] [--style-probe] [--motion-probe | --motion-performance | --resize-performance] [--no-outer-glow] [--no-inner-glow] [--no-edge] [--sigma 0...40] [--foreground-probe] [--width-px N --height-px N] [--duration SECONDS] [--output DIRECTORY]")
    exit(0)
}

do {
    let options = try LaunchOptions(arguments: Array(CommandLine.arguments.dropFirst()))
    // The executable entry point runs on the main thread, before AppKit's run loop.
    try MainActor.assumeIsolated {
    let delegate = try LabDelegate(options: options)
    let app = NSApplication.shared
    app.setActivationPolicy(options.calibration ? .regular : .accessory)
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
    exit(delegate.exitStatus)
    }
} catch {
    fputs("GlassFrameLab: \(error)\n", stderr)
    exit(2)
}
