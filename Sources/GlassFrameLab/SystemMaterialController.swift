import AppKit
import LabSupport

/// The actual shared probe actions; neither backend inherits the other's rendering lifecycle.
@MainActor protocol FlowRuntime: AnyObject {
    var borderFlow: BorderFlowStyle { get }
    func applyBorderFlow(_ next: BorderFlowStyle) throws
    func visibilityChanged()
    func snapshot() -> [String: Any]
}
extension RealtimeGlassController: FlowRuntime {}

@MainActor final class SystemMaterialController: FlowRuntime {
    private weak var window: NSWindow?
    private weak var surface: FrameSurface?
    private let style: GlassStyle
    private(set) var borderFlow: BorderFlowStyle
    private(set) var renderer: SystemFlowRenderer?
    private(set) var decorationError: String?
    private var clock = BorderFlowClock()
    private var pauses: Set<String> = []
    private var motion: Set<String> = []
    private var desktop: Set<String> = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var wake: DispatchWorkItem?
    private var cadence = RenderCadence()
    private var dirty = true
    private var stagingGeometry = false
    private var stopped = false
    private var revision = 0
    private var light = 1.0
    private var themeFrom = 1.0
    private var themeTarget = 1.0
    private var themeBegan = 0.0
    private var reduceMotionOverride: Bool?
    private var now: Double { ProcessInfo.processInfo.systemUptime }
    private var reduceMotion: Bool { reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private var available: Bool { !stopped && window?.isVisible == true && !NSApp.isHidden && pauses.isEmpty && desktop.isEmpty }
    private var active: Bool { borderFlow.enabled && !clock.finished(at: now,style: borderFlow) && renderer != nil }
    private var themeAnimating: Bool { light != themeTarget }
    private var fps: Int {
        switch ProcessInfo.processInfo.thermalState {
        case .critical: return 10
        case .serious: return 15
        default: return ProcessInfo.processInfo.isLowPowerModeEnabled ? 15 : 30
        }
    }

    init(window: NSWindow, style: GlassStyle, flow: BorderFlowStyle, forceMetalUnavailable: Bool) {
        self.window = window
        self.surface = window.contentView as? FrameSurface
        self.style = style
        self.borderFlow = flow
        surface?.showSystemMaterial()
        light = appearanceLight(); themeTarget = light; themeFrom = light
        do {
            if forceMetalUnavailable { throw OptionError.invalid("Injected Metal decoration initialization failure") }
            let overlay = try SystemFlowRenderer(frame: window.contentView!.bounds)
            renderer = overlay
            overlay.view.isHidden = true
            surface?.installSystemOverlay(overlay.view)
        } catch { decorationError = String(describing: error); surface?.flowUnavailable = true }
        surface?.appearanceChanged = { [weak self] in self?.appearanceChanged() }
        surface?.dragActivity = { [weak self] in self?.setFlowMotion("drag",active: $0) }
        surface?.flowEnabled = { [weak self] in self?.borderFlow.enabled == true && self?.renderer != nil }
        if renderer != nil {
            surface?.flowToggle = { [weak self] in
                guard let self else { return }
                var flow = self.borderFlow; flow.enabled.toggle()
                try? self.applyBorderFlow(flow) // Existing validated style; only a Boolean changes.
            }
        }
        observe(NotificationCenter.default, NSApplication.didHideNotification) { $0.visibilityChanged() }
        observe(NotificationCenter.default, NSApplication.didUnhideNotification) { $0.visibilityChanged() }
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { $0.tick() }
        let workspace = NSWorkspace.shared.notificationCenter
        for (name,reason,paused) in [(NSWorkspace.sessionDidResignActiveNotification,"session",true),
                                    (NSWorkspace.sessionDidBecomeActiveNotification,"session",false),
                                    (NSWorkspace.willSleepNotification,"sleep",true),(NSWorkspace.didWakeNotification,"sleep",false),
                                    (NSWorkspace.screensDidSleepNotification,"display",true),(NSWorkspace.screensDidWakeNotification,"display",false)] {
            observe(workspace,name) { controller in
                if paused { controller.pauses.insert(reason) } else { controller.pauses.remove(reason) }
                controller.tick()
            }
        }
        observe(workspace, NSWorkspace.didActivateApplicationNotification) { $0.tick() }
        observe(workspace, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { $0.refresh() }
        tick()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping (SystemMaterialController) -> Void) {
        observers.append((center,center.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        }))
    }
    private func appearanceLight() -> Double {
        surface?.effectiveAppearance.bestMatch(from: [.darkAqua,.aqua]) == .darkAqua ? 0 : 1
    }
    private func appearanceChanged() {
        updateTheme()
        themeFrom = light; themeTarget = appearanceLight(); themeBegan = now
        if !active || reduceMotion { light = themeTarget }
        refresh()
    }
    private func updateTheme() {
        // A static/reduced-motion render must use the final theme immediately.
        // Updating only the diagnostic weight would leave the presented frame stale.
        if reduceMotion || !active { light = themeTarget; return }
        let t = min(1,max(0,(now-themeBegan)/0.2))
        light = themeFrom+(themeTarget-themeFrom)*t
        if t >= 1 { light = themeTarget }
    }
    func applyBorderFlow(_ next: BorderFlowStyle) throws {
        let next = try next.validated()
        if next.enabled != borderFlow.enabled || next.mode != borderFlow.mode { clock.reset() }
        borderFlow = next
        refresh()
    }
    func setFlowMotion(_ reason: String, active: Bool) {
        if active { motion.insert(reason) } else { motion.remove(reason) }
        refresh()
    }
    func visibilityChanged() { tick() }
    func tick() {
        let next = DesktopAvailability.blockers(for: window?.screen)
        if next != desktop { desktop = next; refresh() }
        else { refresh(markDirty: false) }
    }
    func updateGeometry() { refresh() }
    func finishTransition() { setFlowMotion("transition",active:false) }
    func freezePhaseForTesting(_ phase: Double) {
        clock.reset()
        clock.setRunning(true,at:now-phase*borderFlow.period)
        clock.setRunning(false,at:now)
        setFlowMotion("test_static",active:true)
    }
    func setReduceMotionForTesting(_ value: Bool?) { reduceMotionOverride = value; refresh() }

    private func refresh(markDirty: Bool = true) {
        if reduceMotion { light = themeTarget }
        clock.setRunning(available && active && motion.isEmpty && !reduceMotion, at:now)
        if !available || !active {
            wake?.cancel(); wake = nil
            revision += 1
            renderer?.view.isHidden = true
            dirty = true
            return
        }
        if markDirty { dirty = true }
        requestRender()
    }

    private func requestRender() {
        guard !stagingGeometry, available, active, let renderer, !renderer.inFlight else { return }
        guard dirty || clock.isRunning || themeAnimating else { return }
        guard wake == nil else { return }
        let delay = cadence.delay(now:now,frameRate:fps)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.wake = nil
            self.submit()
        }
        wake = work
        DispatchQueue.main.asyncAfter(deadline:.now()+delay,execute:work)
    }
    private func submit() {
        guard available, active, let renderer, let window, !renderer.inFlight else { refresh(markDirty:false); return }
        updateTheme()
        dirty = false
        let token = revision
        let phase = clock.phase(at:now,period:borderFlow.period)
        cadence.didSubmit(at:now)
        Task { @MainActor in
            do {
                _ = try await renderer.render(size:window.frame.size,scale:window.backingScaleFactor,style:style,
                    flow:borderFlow,phase:phase,light:light,beforePresent: { [self] in
                        guard token == revision, available, active else { return false }
                        renderer.view.isHidden = false
                        return true
                    })
            } catch { disableDecoration(error) }
            refresh(markDirty:false)
        }
    }

    func stageGeometry(_ frame: CGRect, screen: NSScreen, apply: @escaping () -> Void, completion: @escaping (Bool) -> Void) {
        revision += 1
        stagingGeometry = true
        wake?.cancel(); wake = nil
        Task { @MainActor in
            // One command in flight; bounded by its completion, no queue of frames.
            await renderer?.waitUntilIdle()
            defer { stagingGeometry = false; refresh() }
            guard !stopped else { completion(false); return }
            guard available, active, let renderer else { apply(); completion(true); return }
            updateTheme()
            let token = revision
            do {
                let presented = try await renderer.render(size:frame.size,scale:screen.backingScaleFactor,style:style,
                    flow:borderFlow,phase:clock.phase(at:now,period:borderFlow.period),light:light,beforePresent: { [self] in
                        guard token == revision, available, active else { return false }
                        apply()
                        surface?.layoutSubtreeIfNeeded()
                        renderer.view.isHidden = false
                        return true
                    })
                completion(presented)
            } catch { disableDecoration(error); apply(); completion(true) }
            refresh()
        }
    }
    private func disableDecoration(_ error: Error) {
        decorationError = String(describing:error)
        renderer?.view.isHidden = true
        renderer?.view.removeFromSuperview()
        renderer = nil
        surface?.flowToggle = nil
        surface?.flowUnavailable = true
        refresh(markDirty:false)
    }
    func stop() async {
        stopped = true; refresh(markDirty:false)
        observers.forEach { $0.0.removeObserver($0.1) }; observers.removeAll()
        await renderer?.waitUntilIdle()
    }
    func snapshot() -> [String: Any] {
        ["backend":"system", "appearance_source":"effectiveAppearance", "appearance_light_weight":light,
         "appearance_target":themeTarget, "last_presented_light_weight":renderer?.lastPresentedLight ?? -1, "material_visible":available && surface?.systemMaterialActive == true,
         "native_material":surface?.systemMaterialName ?? "uninitialized", "fallback_reason":"none", "capture_service_initializations":LocalCaptureService.initializationCount,
         "flow_enabled":borderFlow.enabled, "flow_phase":clock.phase(at:now,period:borderFlow.period),
         "flow_running":clock.isRunning, "flow_finished":clock.finished(at:now,style:borderFlow),
         "flow_motion_reasons":motion.sorted(), "flow_visible":renderer?.view.isHidden == false,
         "flow_mode":borderFlow.mode.rawValue, "flow_period":borderFlow.period, "flow_target_fps":fps,
         "gpu_submissions":renderer?.submissions ?? 0, "gpu_in_flight":renderer?.inFlight ?? false,
         "decoration_available":renderer != nil, "decoration_error":decorationError ?? "none",
         "desktop_blockers":desktop.sorted(), "pause_reasons":pauses.sorted(),
         "reduce_motion":reduceMotion, "reduce_motion_source":reduceMotionOverride == nil ? "system" : "test_override",
         "reduce_transparency":NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
         "window_visible":window?.isVisible == true, "overlay_animation_pending":wake != nil]
    }
}
