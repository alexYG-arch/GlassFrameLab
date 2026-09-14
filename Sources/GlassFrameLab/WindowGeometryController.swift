import AppKit
import LabSupport

@MainActor final class WindowGeometryController {
    private weak var window: NSWindow?
    private var requested: FramePixelSize
    private var centerAnchor: CGPoint?
    private var pending: DispatchWorkItem?
    private var movePending: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    private var applying = false
    private var lastScreenID: UInt32?
    private var lastResult: FrameGeometryResult?
    private var animationTimer: Timer?
    private var preparation: Task<Void, Never>?
    private var movement: Task<Void, Never>?
    private var movementEnd: DispatchWorkItem?
    private var nextOrigin: NSPoint?
    private var revision = 0
    private let onCommit: (FrameGeometryResult, Int) -> Void
    private let onError: (Error) -> Void
    private let beginTransition: (() -> Void)?
    private let prepareTransition: ((CGRect, NSScreen) async -> Bool)?
    private let finishTransition: (() -> Void)?
    private let stageGeometry: ((FrameGeometryResult, NSScreen, @escaping () -> Void, @escaping (Bool) -> Void) -> Void)?
    private(set) var commitCount = 0

    init(window: NSWindow, requested: FramePixelSize, onCommit: @escaping (FrameGeometryResult, Int) -> Void,
         onError: @escaping (Error) -> Void, beginTransition: (() -> Void)? = nil, prepareTransition: ((CGRect, NSScreen) async -> Bool)? = nil,
         finishTransition: (() -> Void)? = nil,
         stageGeometry: ((FrameGeometryResult, NSScreen, @escaping () -> Void, @escaping (Bool) -> Void) -> Void)? = nil) {
        self.window = window
        self.requested = requested
        self.onCommit = onCommit
        self.onError = onError
        self.beginTransition = beginTransition
        self.prepareTransition = prepareTransition
        self.finishTransition = finishTransition
        self.stageGeometry = stageGeometry
        for name in [NSWindow.didMoveNotification, NSWindow.didChangeScreenNotification, NSWindow.didChangeBackingPropertiesNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.applying else { return }
                    self.centerAnchor = nil
                    self.cancelAnimation(preserveSize: true)
                    guard self.movePending == nil else { return }
                    let work = DispatchWorkItem { [weak self] in self?.movePending = nil; self?.commit() }
                    self.movePending = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 30, execute: work)
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.centerAnchor = nil; self?.cancelAnimation(preserveSize: false); self?.commit() }
        })
        commit()
    }

    func request(_ size: FramePixelSize, duration: Double = 0) {
        if centerAnchor == nil, let window { centerAnchor = CGPoint(x: window.frame.midX, y: window.frame.midY) }
        movementEnd?.cancel(); movementEnd = nil
        movement?.cancel(); movement = nil; nextOrigin = nil
        cancelAnimation(preserveSize: false, keepSampling: true)
        requested = size
        beginTransition?()
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if duration.isFinite, duration > 0 { self.animate(duration: min(duration, 2)) }
            else { self.animate(duration: 0) }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(75), execute: work)
    }

    func move(to origin: NSPoint) {
        centerAnchor = nil
        movementEnd?.cancel(); movementEnd = nil
        cancelAnimation(preserveSize: true)
        pending?.cancel()
        nextOrigin = origin
        beginTransition?()
        guard movement == nil else { return }
        movement = Task { @MainActor [weak self] in
            guard let self else { return }
            while let origin = self.nextOrigin, let window = self.window, !Task.isCancelled {
                self.nextOrigin = nil
                do {
                    let (target, screen) = try self.resolve(at: CGRect(origin: origin, size: window.frame.size))
                    let ready = await self.prepareTransition?(window.glassFrame.union(target.glassFrame), screen) ?? true
                    guard !Task.isCancelled else { return }
                    if ready {
                        _ = await withCheckedContinuation { continuation in
                            self.apply(target, screen: screen) { continuation.resume(returning: $0) }
                        }
                    }
                    guard !Task.isCancelled else { return }
                    guard ready else { self.finishTransition?(); break }
                } catch {
                    if !Task.isCancelled { self.onError(error) }
                    break
                }
            }
            self.movement = nil
            guard !Task.isCancelled else { return }
            let end = DispatchWorkItem { [weak self] in
                self?.movementEnd = nil; self?.finishTransition?()
            }
            self.movementEnd = end
            DispatchQueue.main.asyncAfter(deadline: .now()+0.15, execute: end)
        }
    }

    private func resolve(at proposedFrame: CGRect? = nil) throws -> (FrameGeometryResult, NSScreen) {
        guard let window else { throw OptionError.invalid("Window unavailable") }
        var reference = proposedFrame ?? window.frame
        if proposedFrame == nil, let anchor = centerAnchor {
            reference.origin = CGPoint(x: anchor.x-reference.width/2, y: anchor.y-reference.height/2)
        }
        let preferred = window.screen ?? NSScreen.main
        let candidates = NSScreen.screens.sorted { a, b in
            let ai = a.frame.intersection(reference), bi = b.frame.intersection(reference)
            let aa = ai.isNull ? 0 : ai.width * ai.height, ba = bi.isNull ? 0 : bi.width * bi.height
            if aa != ba { return aa > ba }
            if a == preferred { return b != preferred }
            if b == preferred { return false }
            return hypot(a.frame.midX-reference.midX, a.frame.midY-reference.midY)
                < hypot(b.frame.midX-reference.midX, b.frame.midY-reference.midY)
        }
        guard let screen = candidates.first else { throw OptionError.invalid("No connected display") }
        let result = try FrameGeometry.resolve(requested: requested, backingScale: screen.backingScaleFactor,
                                               visibleFrame: screen.visibleFrame, currentFrame: reference,
                                               shadowInset: (window as? FramePanel)?.shadowInset ?? 0, alignToWindowPoints: true)
        if proposedFrame == nil, let anchor = centerAnchor,
           abs(result.frame.midX-anchor.x)>1 || abs(result.frame.midY-anchor.y)>1 {
            // A screen constraint changes the usable anchor; pixel rounding does not.
            centerAnchor = CGPoint(x: result.frame.midX, y: result.frame.midY)
        }
        return (result, screen)
    }

    private func commit() {
        guard window != nil, !applying else { return }
        do { let (result, screen) = try resolve(); apply(result, screen: screen) }
        catch { onError(error) }
    }

    private func apply(_ result: FrameGeometryResult, screen: NSScreen, completion: @escaping (Bool) -> Void = { _ in }) {
        guard let window else { completion(false); return }
        let screenID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        if let last = lastResult, last.frame == result.frame, last.actualPixels == result.actualPixels,
           last.sizeLimited == result.sizeLimited, last.usedDefaultInput == result.usedDefaultInput,
           lastScreenID == screenID, window.frame == result.frame { completion(true); return }
        let commit = { [weak self, weak window] in
            guard let self, let window else { return }
            self.applying = true
            window.setFrame(result.frame, display: true)
            self.applying = false
            self.lastResult = result
            self.lastScreenID = screenID
            self.commitCount += 1
            self.onCommit(result, self.commitCount)
        }
        if let stageGeometry { stageGeometry(result, screen, commit, completion) }
        else { commit(); completion(true) }
    }

    private func animate(duration: Double) {
        guard let window else { return }
        do {
            let (target, screen) = try resolve()
            let start = window.frame
            let fixedCenter = abs(start.midX-target.frame.midX)<=1 && abs(start.midY-target.frame.midY)<=1 ? centerAnchor : nil
            guard start != target.frame else {
                apply(target, screen: screen) { [weak self] _ in self?.finishTransition?() }
                return
            }
            let ticket = revision
            let envelope = window.glassFrame.union(target.glassFrame)
            preparation = Task { @MainActor [weak self] in
                guard let self else { return }
                let ready = await self.prepareTransition?(envelope, screen) ?? true
                guard !Task.isCancelled, ticket == self.revision else { return }
                self.preparation = nil
                guard ready else { self.finishTransition?(); return }
                if duration == 0 {
                    self.apply(target, screen: screen) { [weak self] _ in self?.finishTransition?() }
                    return
                }
                let began = ProcessInfo.processInfo.systemUptime
                let advance: @MainActor @Sendable () -> Void = { [weak self] in
                        guard let self, ticket == self.revision else { return }
                        guard let window = self.window else { self.animationTimer?.invalidate(); return }
                        guard window.isVisible else {
                            self.animationTimer?.invalidate(); self.animationTimer = nil; self.finishTransition?(); return
                        }
                        let t = min(1, (ProcessInfo.processInfo.systemUptime-began)/duration)
                        var frame = FrameGeometry.interpolate(from: start, to: target.frame, progress: t)
                        if let center = fixedCenter {
                            frame.origin = CGPoint(x: center.x-frame.width/2, y: center.y-frame.height/2)
                        }
                        let inset = (window as? FramePanel)?.shadowInset ?? 0
                        do {
                            let value = try FrameGeometry.resolve(requested: FramePixelSize(width: (frame.width-2*inset)*screen.backingScaleFactor,
                                                                                           height: (frame.height-2*inset)*screen.backingScaleFactor),
                                                                  backingScale: screen.backingScaleFactor, visibleFrame: screen.visibleFrame,
                                                                  currentFrame: frame, shadowInset: inset, alignToWindowPoints: true)
                            self.apply(t == 1 ? target : value, screen: screen) { [weak self] applied in
                                guard let self, applied, t == 1, ticket == self.revision else { return }
                                self.animationTimer = nil; self.finishTransition?()
                            }
                            if t == 1 { self.animationTimer?.invalidate() }
                        } catch { self.animationTimer?.invalidate(); self.finishTransition?(); self.onError(error) }
                }
                self.animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
                    MainActor.assumeIsolated { advance() }
                }
            }
        } catch { onError(error) }
    }

    private func cancelAnimation(preserveSize: Bool, keepSampling: Bool = false) {
        let active = preparation != nil || animationTimer != nil
        revision += 1
        preparation?.cancel(); preparation = nil
        animationTimer?.invalidate(); animationTimer = nil
        if active {
            if preserveSize, let window {
                // A backing notification may already expose the destination scale.
                // Preserve the last committed pixels rather than multiplying old points by it.
                let pixels = lastResult?.actualPixels ?? CGSize(width: window.glassFrame.width*window.backingScaleFactor,
                                                                height: window.glassFrame.height*window.backingScaleFactor)
                requested = FramePixelSize(width: pixels.width, height: pixels.height)
            }
            if !keepSampling { finishTransition?() }
        }
    }

    deinit {
        pending?.cancel(); movePending?.cancel(); preparation?.cancel(); movement?.cancel(); movementEnd?.cancel(); animationTimer?.invalidate()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}
