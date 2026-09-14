import AppKit
import LabSupport

@MainActor final class RealtimeGlassController {
    let capture: LocalCaptureService
    let renderer: GlassRenderer
    private weak var window: NSWindow?
    private let onError: (Error) -> Void
    private var rendering = false
    private(set) var borderFlow = BorderFlowStyle()
    private var flowClock = BorderFlowClock()
    private var flowEpoch = 0
    private var renderedFlowEpoch = -1
    private var flowMotion: Set<String> = []
    private var flowGeometryEnd: DispatchWorkItem?
    private var lastFlowPhase = 0.0
    private var flowVisible = false
    private lazy var lifecycle = RunIntentCoordinator(start: { [weak self] in await self?.startCapture() },
                                                       stop: { [weak self] in await self?.stopCapture() },
                                                       suspend: { [weak self] in
        self?.pauseFlow()
        self?.renderer.view.alphaValue = 0
        self?.renderWake?.cancel(); self?.renderWake = nil
        self?.renderCadence = RenderCadence()
        self?.pendingGeometry?.finish(false); self?.pendingGeometry = nil
        self?.inFlightGeometry?.finish(false)
        self?.geometryEpoch += 1
        self?.capture.suspendFramesAndPendingStart()
    })
    private var pauseReasons: Set<String> = []
    private var desktopBlockers: Set<String> = []
    private var lastSequence = -1
    private var styleRevision = 0
    private var renderedStyleRevision = -1
    private var lastRenderedGlassFrame: CGRect?
    private var motionActive = false
    private var motionUntil = 0.0
    private var pendingGeometry: GeometryPresentation?
    private var inFlightGeometry: GeometryPresentation?
    private var geometryEpoch = 0
    private var cancelledGeometryFrames = 0
    private var mismatchedGeometryFrames = 0
    private var materialEpoch = 0
    private var fallbackReason: String? = "starting"
    private var renderWake: DispatchWorkItem?
    private var renderCadence = RenderCadence()
    private var lastChange = 0.0
    private var consecutiveChanges = 0
    private var cadenceChangedAt = 0.0
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private(set) var state = "idle"
    var materialStatus: String {
        if fallbackReason == nil { return "实时毛玻璃已连接" }
        if capture.state == "permission_required" { return "替代材质：需要屏幕录制权限；流光暂停" }
        return "替代材质：背景不可用（\(fallbackReason ?? capture.state)）；流光暂停"
    }

    init(window: NSWindow, style: GlassStyle, adaptive: Bool = true, borderFlow: BorderFlowStyle = BorderFlowStyle(), forceAccessDenied: Bool = false, onError: @escaping (Error) -> Void) throws {
        self.window = window
        self.borderFlow = try borderFlow.validated()
        desktopBlockers = DesktopAvailability.blockers(for: window.screen)
        self.onError = onError
        capture = LocalCaptureService(sigma: style.sigma, forceAccessDenied: forceAccessDenied)
        renderer = try GlassRenderer(frame: window.contentView!.bounds, style: style, adaptive: adaptive)
        window.contentView?.addSubview(renderer.view)
        (window.contentView as? FrameSurface)?.carrierVisible = false
        (window.contentView as? FrameSurface)?.showFallback(true)
        renderer.view.alphaValue = 0
        capture.setFrameHandler { [weak self] in
            Task { @MainActor in self?.requestRender() }
        }
        capture.setStateHandler { [weak self] in
            guard let self else { return }
            self.syncFallback()
            if self.capture.state == "rebind_required" { self.restartCapture() }
        }
        observe(.default, NSApplication.didHideNotification) { [weak self] in self?.visibilityChanged() }
        observe(.default, NSApplication.didUnhideNotification) { [weak self] in self?.visibilityChanged() }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.didActivateApplicationNotification) { [weak self] in self?.visibilityChanged() }
        for (reason, pause, resume) in [("sleep", NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification),
                                         ("display", NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification),
                                         ("session", NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification)] {
            observe(workspace, pause) { [weak self] in self?.pauseReasons.insert(reason); self?.visibilityChanged() }
            observe(workspace, resume) { [weak self] in self?.pauseReasons.remove(reason); self?.visibilityChanged() }
        }
    }

    private var canRun: Bool { window?.isVisible == true && !NSApp.isHidden && pauseReasons.isEmpty && desktopBlockers.isEmpty }

    func visibilityChanged() {
        desktopBlockers = DesktopAvailability.blockers(for: window?.screen)
        syncFallback()
        lifecycle.request(canRun)
    }

    private func setFallback(_ reason: String?) {
        if reason != fallbackReason { materialEpoch += 1; fallbackReason = reason }
        if reason != nil {
            pauseFlow()
            renderer.view.alphaValue = 0
            renderWake?.cancel(); renderWake = nil
        }
        (window?.contentView as? FrameSurface)?.showFallback(reason != nil && canRun)
    }

    private func syncFallback() {
        guard canRun else { setFallback("paused"); return }
        if capture.state != "capturing" { setFallback(capture.state); return }
        if let issue = capture.frameIssue { setFallback(issue); return }
        if capture.latestBuffer() == nil { setFallback("waiting_frame") }
        // A fallback is removed only by a successfully completed, valid render.
    }

    func restartCapture() {
        setFallback("restarting")
        lifecycle.request(false)
        lifecycle.request(canRun)
    }

    func start() async {
        desktopBlockers = DesktopAvailability.blockers(for: window?.screen)
        lifecycle.request(canRun)
        await lifecycle.waitUntilSettled()
    }

    private func startCapture() async {
        guard canRun, capture.state != "capturing", let window else { return }
        state = "starting"
        await capture.start(for: window)
        guard canRun, lifecycle.desiredRunning else { return }
        state = capture.state
        if capture.state == "capturing" { requestRender() }
        syncFallback()
    }

    func stop() async {
        lifecycle.request(false)
        await lifecycle.waitUntilSettled()
    }

    private func stopCapture() async {
        renderer.view.alphaValue = 0
        await capture.stop()
        capture.setEnvelope(nil)
        motionActive = false
        flowMotion.removeAll()
        flowGeometryEnd?.cancel(); flowGeometryEnd = nil
        await renderer.waitForIdle()
        state = "paused"
        consecutiveChanges = 0
        syncFallback()
    }

    func updateGeometry() {
        guard let window else { return }
        if !motionActive {
            setFlowMotion("geometry", active: true)
            flowGeometryEnd?.cancel()
            let end = DispatchWorkItem { [weak self] in
                self?.flowGeometryEnd = nil
                self?.setFlowMotion("geometry", active: false)
            }
            flowGeometryEnd = end
            DispatchQueue.main.asyncAfter(deadline: .now()+0.15, execute: end)
        }
        if capture.state == "capturing", let screen = window.screen, !capture.isBound(to: screen) {
            restartCapture()
            return
        }
        motionUntil = ProcessInfo.processInfo.systemUptime + 0.3
        if let frame = capture.latestFrame(), canProject(frame, into: window) {} else { renderer.view.alphaValue = 0 }
        capture.requestGeometryUpdate(for: window)
        requestRender()
    }

    func prepareTransition(envelope: CGRect, screen: NSScreen) async -> Bool {
        guard canRun else { return false }
        setFlowMotion("transition", active: true)
        if !capture.isBound(to: screen) || capture.frameIssue != nil {
            motionActive = false
            return true // The fallback can commit geometry without a captured sample.
        }
        geometryEpoch += 1
        inFlightGeometry?.finish(false)
        pendingGeometry?.finish(false); pendingGeometry = nil
        motionActive = true
        tick()
        if let window, let frame = capture.latestFrame(), canProject(frame, into: window),
           frame.mapping.sourceFrameOnScreen.contains(envelope) {
            capture.setEnvelope(frame.mapping.glassFrame)
            return true
        }
        capture.setEnvelope(envelope)
        // Bounded preparation only while a requested transition is active.
        for _ in 0..<60 {
            guard !Task.isCancelled, canRun else { return false }
            if let frame = capture.latestFrame(), frame.mapping.glassFrame == envelope { return true }
            do { try await Task.sleep(nanoseconds: 16_666_667) } catch { return false }
        }
        return false
    }

    func finishTransition() {
        geometryEpoch += 1
        inFlightGeometry?.finish(false)
        pendingGeometry?.finish(false)
        pendingGeometry = nil
        motionActive = false
        capture.setEnvelope(nil)
        setFlowMotion("transition", active: false)
    }

    func stageGeometry(_ frame: CGRect, screen: NSScreen, apply: @escaping () -> Void, completion: @escaping (Bool) -> Void) {
        if !capture.isBound(to: screen) || capture.frameIssue != nil || capture.latestBuffer() == nil {
            setFallback("geometry_rebind")
            geometryEpoch += 1
            pendingGeometry?.finish(false); pendingGeometry = nil
            inFlightGeometry?.finish(false)
            apply()
            completion(true)
            return
        }
        // Keep the frame already on the GPU. New ticks in the same transition queue
        // the next frame; cancelling the transition invalidates both via its epoch.
        if pendingGeometry !== inFlightGeometry { pendingGeometry?.finish(false) }
        pendingGeometry = GeometryPresentation(frame: frame, epoch: geometryEpoch, apply: apply, completion: completion)
        requestRender()
    }

    private func canProject(_ frame: CapturedFrame, into window: NSWindow) -> Bool {
        guard let screen = window.screen else { return false }
        return frame.mapping.scale == screen.backingScaleFactor && frame.mapping.displayFrame == screen.frame
            && frame.mapping.sigma == renderer.style.sigma && frame.mapping.sourceFrameOnScreen.contains(window.glassFrame)
    }

    func applyStyle(_ style: GlassStyle) throws {
        let style = try style.validated()
        guard style != renderer.style, let window else { return }
        let glass = window.glassFrame
        let oldInset = (window as? FramePanel)?.shadowInset ?? 0
        try renderer.applyStyle(style)
        (window as? FramePanel)?.style = style
        window.contentView?.needsLayout = true
        window.contentView?.needsDisplay = true
        styleRevision += 1
        if oldInset != style.shadowExtent {
            window.setFrame(glass.insetBy(dx: -style.shadowExtent, dy: -style.shadowExtent), display: true)
        }
        capture.setSigma(style.sigma)
        requestRender()
    }

    func tick() {
        let blockers = DesktopAvailability.blockers(for: window?.screen)
        if blockers != desktopBlockers { visibilityChanged() }
        // Retry only when access actually changes; denied access must not start
        // an endless capture/restart loop. Reuses the existing one-second tick.
        if canRun, capture.state == "permission_required", capture.hasScreenAccess {
            restartCapture()
        }
        guard canRun, capture.state == "capturing" else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let thermal = ProcessInfo.processInfo.thermalState
        let cap = thermal == .critical ? 10 : ((thermal == .serious || ProcessInfo.processInfo.isLowPowerModeEnabled) ? 15 : 30)
        if now - cadenceChangedAt < 0.4, capture.frameRate <= cap { return }
        let active = motionActive || now < motionUntil || (now - lastChange < 2 && (consecutiveChanges >= 2 || capture.frameRate == 30))
        let desired = active ? cap : min(15, cap)
        if desired != capture.frameRate {
            cadenceChangedAt = now
            consecutiveChanges = 0
            capture.setFrameRate(desired)
        }
        state = desired == 30 ? "dynamic" : "static_or_reduced"
    }

    func applyBorderFlow(_ style: BorderFlowStyle) throws {
        let value = try style.validated()
        guard value != borderFlow else { return }
        let restart = value.enabled != borderFlow.enabled || value.mode != borderFlow.mode
        borderFlow = value
        if restart { flowClock.reset() }
        flowEpoch += 1
        renderWake?.cancel(); renderWake = nil
        refreshFlowClock()
        requestRender()
    }

    func setFlowMotion(_ reason: String, active: Bool) {
        let changed = active ? flowMotion.insert(reason).inserted : flowMotion.remove(reason) != nil
        guard changed else { return }
        refreshFlowClock()
        requestRender()
    }

    private func pauseFlow() {
        if flowClock.isRunning {
            flowClock.setRunning(false, at: ProcessInfo.processInfo.systemUptime)
            flowEpoch += 1
        }
    }

    private func refreshFlowClock() {
        let now = ProcessInfo.processInfo.systemUptime
        let visible = borderFlow.enabled && !flowClock.finished(at: now, style: borderFlow)
        let run = visible && flowMotion.isEmpty && canRun && lifecycle.desiredRunning
            && capture.state == "capturing" && capture.frameIssue == nil && fallbackReason == nil
        if run != flowClock.isRunning {
            flowClock.setRunning(run, at: now)
            flowEpoch += 1
            renderWake?.cancel(); renderWake = nil
        }
        if visible != flowVisible { flowVisible = visible; flowEpoch += 1 }
    }

    private var animationFPS: Int {
        let thermal = ProcessInfo.processInfo.thermalState
        if thermal == .critical { return 10 }
        return thermal == .serious || ProcessInfo.processInfo.isLowPowerModeEnabled ? 15 : 30
    }

    private var staleGeometryFrames = 0
    private var nextTestGeometryDelay: UInt64 = 0
    func delayNextGeometryPresentationForTesting() { nextTestGeometryDelay = 350_000_000 }

    private func requestRender() {
        syncFallback()
        refreshFlowClock()
        guard canRun, lifecycle.desiredRunning, capture.state == "capturing", !rendering,
              let window, let frame = capture.latestFrame() else { return }
        let geometry = pendingGeometry
        let glassFrame = geometry?.frame.insetBy(dx: renderer.style.shadowExtent, dy: renderer.style.shadowExtent) ?? window.glassFrame
        guard frame.sequence != lastSequence || styleRevision != renderedStyleRevision || lastRenderedGlassFrame != glassFrame || flowEpoch != renderedFlowEpoch || flowClock.isRunning else {
            if let geometry { pendingGeometry = nil; geometry.apply(); geometry.finish(true) }
            return
        }
        guard canProject(frame, into: window), frame.mapping.sourceFrameOnScreen.contains(glassFrame) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if geometry != nil && !FrameFreshness.allowsGeometry(capturedAt: frame.captureTime, now: now) {
            capture.requestNextValidFrame()
            return
        }
        let delay = renderCadence.delay(now: now, frameRate: flowClock.isRunning ? animationFPS : capture.frameRate)
        if delay > 0 {
            if renderWake == nil {
                let work = DispatchWorkItem { [weak self] in self?.renderWake = nil; self?.requestRender() }
                renderWake = work
                DispatchQueue.main.asyncAfter(deadline: .now()+delay, execute: work)
            }
            return
        }
        renderWake?.cancel(); renderWake = nil
        renderCadence.didSubmit(at: now)
        if frame.sequence != lastSequence {
            consecutiveChanges = now - cadenceChangedAt < 0.4 ? 0 : (now - lastChange < 0.3 ? consecutiveChanges + 1 : 1)
            lastChange = now
        }
        let animationOnly = frame.sequence == lastSequence && glassFrame == lastRenderedGlassFrame
        lastSequence = frame.sequence
        let flowTicket = flowEpoch
        renderedFlowEpoch = flowTicket
        var flow = borderFlow
        flow.enabled = flowVisible
        let phase = flowClock.phase(at: now, period: flow.period)
        let revision = styleRevision
        let materialTicket = materialEpoch
        renderedStyleRevision = revision
        rendering = true
        inFlightGeometry = geometry
        let testDelay = geometry == nil ? 0 : nextTestGeometryDelay
        if geometry != nil { nextTestGeometryDelay = 0 }
        tick()
        Task { @MainActor in
            var deferredGeometry = false
            do {
                _ = try await renderer.render(buffer: frame.buffer, glassFrame: glassFrame,
                                              displayFrame: frame.mapping.displayFrame, sourceRect: frame.mapping.sourceRect,
                                              scale: frame.mapping.scale, captureTime: frame.captureTime, sequence: frame.sequence,
                                              flow: flow, flowPhase: phase, animationOnly: animationOnly,
                                              testPresentationDelay: testDelay, beforePresent: { [weak self] in
                    guard let self, self.canRun, self.lifecycle.desiredRunning, revision == self.styleRevision,
                          materialTicket == self.materialEpoch, flowTicket == self.flowEpoch, self.capture.state == "capturing", self.capture.frameIssue == nil else { return false }
                    if let geometry {
                        guard geometry.epoch == self.geometryEpoch else { self.cancelledGeometryFrames += 1; return false }
                        guard FrameFreshness.allowsGeometry(capturedAt: frame.captureTime, now: ProcessInfo.processInfo.systemUptime) else {
                            self.staleGeometryFrames += 1
                            deferredGeometry = self.pendingGeometry === geometry
                            self.capture.requestNextValidFrame()
                            return false
                        }
                        if self.pendingGeometry === geometry { self.pendingGeometry = nil }
                        geometry.apply()
                        self.lastRenderedGlassFrame = glassFrame
                        geometry.finish(true)
                    }
                    self.lastRenderedGlassFrame = glassFrame
                    if window.glassFrame != glassFrame { self.mismatchedGeometryFrames += 1 }
                    if self.renderer.rasterDiagnostics, window.glassFrame != glassFrame {
                        print("GEOMETRY_MISMATCH target=\(NSStringFromRect(glassFrame)) actual=\(NSStringFromRect(window.glassFrame))")
                    }
                    let matches = window.glassFrame == glassFrame
                    if matches { self.setFallback(nil); self.renderer.view.alphaValue = 1; self.lastFlowPhase = phase }
                    return matches
                })
            } catch {
                self.setFallback("render_failure")
                await self.stop()
                self.state = "failed"
                self.onError(error)
            }
            if !deferredGeometry { geometry?.finish(false) }
            self.inFlightGeometry = nil
            self.rendering = false
            self.requestRender()
        }
    }

    func snapshot() -> [String: Any] {
        var result = capture.snapshot()
        result["runtime_state"] = state
        result["cancelled_geometry_frames"] = cancelledGeometryFrames
        result["stale_geometry_frames"] = staleGeometryFrames
        result["mismatched_geometry_frames"] = mismatchedGeometryFrames
        result["gpu_submissions"] = renderer.submissions
        result["gpu_in_flight"] = rendering ? 1 : 0
        result["intermediate_textures"] = renderer.intermediateTextureCount
        result["texture_allocations"] = renderer.textureAllocations
        result["blur_encodes"] = renderer.blurEncodes
        result["material_statistics_encodes"] = renderer.statisticsEncodes
        result["material_statistics_bytes"] = renderer.statisticsBytes
        result["flow_enabled"] = borderFlow.enabled
        result["flow_running"] = flowClock.isRunning
        result["flow_visible"] = flowVisible
        result["flow_phase"] = lastFlowPhase
        result["flow_frozen_reasons"] = flowMotion.sorted()
        result["style_revision"] = styleRevision
        result["rendered_style_revision"] = renderedStyleRevision
        result["dropped_metric_records"] = renderer.metrics.droppedRecords
        result["pause_reasons"] = pauseReasons.sorted()
        result["desktop_blockers"] = desktopBlockers.sorted()
        result["mouse_ignored"] = window?.ignoresMouseEvents ?? false
        result["rendered_glass_frame_pt"] = lastRenderedGlassFrame.map(NSStringFromRect) ?? "none"
        result["glass_frame_pt"] = window.map { NSStringFromRect($0.glassFrame) } ?? "none"
        result["capture_envelope_pt"] = capture.envelope.map(NSStringFromRect) ?? "none"
        result["geometry_motion_active"] = motionActive
        result["material_visible"] = renderer.view.alphaValue > 0
        result["fallback_visible"] = (window?.contentView as? FrameSurface)?.fallbackActive ?? false
        result["fallback_reason"] = fallbackReason ?? "none"
        result["window_on_active_space"] = window?.isOnActiveSpace ?? false
        result["window_visible"] = window?.isVisible ?? false
        result["selected_display_id"] = (window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        result["selected_backing_scale"] = window?.backingScaleFactor ?? 0
        return result
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, action: @escaping @MainActor () -> Void) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { _ in MainActor.assumeIsolated { action() } }
        observers.append((center, observer))
    }

    deinit { flowGeometryEnd?.cancel(); renderWake?.cancel(); for (center, observer) in observers { center.removeObserver(observer) } }
}

@MainActor private final class GeometryPresentation {
    let frame: CGRect
    let epoch: Int
    let apply: () -> Void
    private var completion: ((Bool) -> Void)?
    init(frame: CGRect, epoch: Int, apply: @escaping () -> Void, completion: @escaping (Bool) -> Void) {
        self.frame = frame; self.epoch = epoch; self.apply = apply; self.completion = completion
    }
    func finish(_ applied: Bool) { let callback = completion; completion = nil; callback?(applied) }
}
