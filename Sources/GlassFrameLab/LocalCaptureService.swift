import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreImage
import LabSupport

/// The capture queue retains one latest pixel buffer, with no per-frame main-queue tasks.
final class LatestCaptureOutput: NSObject, SCStreamOutput {
    private let lock = NSLock()
    private var latest: CapturedFrame?
    private var count = 0
    private var changedCount = 0
    private var accepting = false
    private var mapping: CaptureMapping?
    private var acceptAfter = 0.0
    private var notificationPending = false
    private var notifyNextValidFrame = false
    private var handler: (@Sendable () -> Void)?
    private var difference = "first frame"
    private var unavailable: String?
    private var statusOverride: SCFrameStatus?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let reportedStatus = SCFrameStatus(rawValue: raw) else { return }
        let timestamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        lock.lock()
        guard accepting, let mapping, timestamp >= acceptAfter else { lock.unlock(); return }
        let status = statusOverride ?? reportedStatus
        if status == .blank || status == .suspended || status == .stopped {
            let reason = status == .blank ? "blank" : (status == .suspended ? "suspended" : "stopped")
            let changed = unavailable != reason || latest != nil
            unavailable = reason
            latest = nil
            let notify = changed && !notificationPending ? handler : nil
            if notify != nil { notificationPending = true }
            lock.unlock()
            notify?()
            return
        }
        // ScreenCaptureKit explicitly confirms unchanged display contents with idle.
        // Refresh validity time without creating a new pixel sequence or GPU work.
        if status == .idle {
            if let old = latest, old.mapping == mapping, timestamp > old.captureTime {
                latest = CapturedFrame(buffer: old.buffer, sequence: old.sequence, captureTime: timestamp, mapping: mapping)
            }
            let notify = latest != nil && notifyNextValidFrame && !notificationPending ? handler : nil
            if notify != nil { notificationPending = true; notifyNextValidFrame = false }
            lock.unlock(); notify?(); return
        }
        guard status == .complete, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { lock.unlock(); return }
        count += 1
        guard CVPixelBufferGetWidth(buffer) == mapping.width,
              CVPixelBufferGetHeight(buffer) == mapping.height else { lock.unlock(); return }
        if let old = latest, old.mapping == mapping, Self.equalPixels(old.buffer, buffer, difference: &difference) {
            latest = CapturedFrame(buffer: old.buffer, sequence: old.sequence, captureTime: timestamp, mapping: mapping)
            let notify = notifyNextValidFrame && !notificationPending ? handler : nil
            if notify != nil { notificationPending = true; notifyNextValidFrame = false }
            lock.unlock(); notify?(); return
        }
        changedCount += 1
        unavailable = nil
        latest = CapturedFrame(buffer: buffer, sequence: changedCount, captureTime: timestamp, mapping: mapping)
        let notify = notificationPending ? nil : handler
        if notify != nil { notificationPending = true; notifyNextValidFrame = false }
        lock.unlock()
        notify?()
    }

    func requestNextValidFrame() {
        lock.lock(); notifyNextValidFrame = true; lock.unlock()
    }

    private static func equalPixels(_ a: CVPixelBuffer, _ b: CVPixelBuffer, difference: inout String) -> Bool {
        guard CVPixelBufferGetWidth(a) == CVPixelBufferGetWidth(b), CVPixelBufferGetHeight(a) == CVPixelBufferGetHeight(b) else { return false }
        let aStatus = CVPixelBufferLockBaseAddress(a, .readOnly)
        guard aStatus == kCVReturnSuccess else { difference = "old lock failed: \(aStatus)"; return false }
        defer { CVPixelBufferUnlockBaseAddress(a, .readOnly) }
        let bStatus = CVPixelBufferLockBaseAddress(b, .readOnly)
        guard bStatus == kCVReturnSuccess else { difference = "new lock failed: \(bStatus)"; return false }
        defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        guard let ap = CVPixelBufferGetBaseAddress(a), let bp = CVPixelBufferGetBaseAddress(b) else { return false }
        let bytes = CVPixelBufferGetWidth(a) * 4
        for row in 0..<CVPixelBufferGetHeight(a) {
            let ar = ap.advanced(by: row * CVPixelBufferGetBytesPerRow(a)).assumingMemoryBound(to: UInt8.self)
            let br = bp.advanced(by: row * CVPixelBufferGetBytesPerRow(b)).assumingMemoryBound(to: UInt8.self)
            if memcmp(ar, br, bytes) != 0 {
                if let column = (0..<bytes).first(where: { ar[$0] != br[$0] }) {
                    difference = "row=\(row) byte=\(column) old=\(ar[column]) new=\(br[column])"
                }
                return false
            }
        }
        difference = "identical"
        return true
    }

    func snapshot() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        return ["received_complete_frames": count, "changed_frames": changedCount, "last_pixel_difference": difference,
                "unavailable_frame_reason": unavailable ?? "",
                "test_frame_status_override": statusOverride.map { String($0.rawValue) } ?? "none",
                "retained_buffers": latest == nil ? 0 : 1,
                "buffer_width_px": latest.map { CVPixelBufferGetWidth($0.buffer) } ?? 0,
                "buffer_height_px": latest.map { CVPixelBufferGetHeight($0.buffer) } ?? 0]
    }

    func writeLatestPNG(to url: URL) throws {
        guard let buffer = latestFrame()?.buffer else { throw OptionError.invalid("No complete capture frame to export") }
        try Self.writePNG(buffer: buffer, to: url)
    }

    static func writePNG(buffer: CVPixelBuffer, to url: URL) throws {
        try CIContext().writePNGRepresentation(of: CIImage(cvPixelBuffer: buffer), to: url,
                                               format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
    }

    func latestBuffer() -> CVPixelBuffer? { latestFrame()?.buffer }

    func latestFrame(acknowledge: Bool = false) -> CapturedFrame? {
        lock.lock()
        defer { lock.unlock() }
        if acknowledge { notificationPending = false }
        return latest
    }

    func setHandler(_ handler: (@Sendable () -> Void)?) {
        lock.lock()
        self.handler = handler
        notificationPending = false
        lock.unlock()
    }

    func setMapping(_ mapping: CaptureMapping) {
        lock.lock()
        self.mapping = mapping
        acceptAfter = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        accepting = true
        notificationPending = false
        lock.unlock()
    }

    func resumeMappingIfNeeded(_ value: CaptureMapping) {
        lock.lock(); defer { lock.unlock() }
        if !accepting {
            mapping = value
            acceptAfter = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
            accepting = true
        }
    }

    func setAccepting(_ value: Bool, preserveFrame: Bool = false) {
        lock.lock()
        accepting = value
        if !value { if !preserveFrame { latest = nil; unavailable = nil }; notificationPending = false }
        lock.unlock()
    }

    func overrideStatusForTesting(_ status: SCFrameStatus?) {
        lock.lock(); statusOverride = status; lock.unlock()
    }

    var frameIssue: String? {
        lock.lock(); defer { lock.unlock() }
        return unavailable
    }
}

@MainActor final class LocalCaptureService: NSObject, SCStreamDelegate {
    private(set) static var initializationCount = 0
    private(set) var state = "idle" {
        didSet { if state != oldValue { stateHandler?() } }
    }
    private var stateHandler: (() -> Void)?
    private(set) var errorDescription: String?
    private var stream: SCStream?
    private var displayID: CGDirectDisplayID?
    private var generation = 0
    private var updating = false
    private weak var pendingWindow: NSWindow?
    private let output = LatestCaptureOutput()
    private let queue = DispatchQueue(label: "GlassFrame.localCapture")
    private(set) var sourceRect = CGRect.zero
    private var sigma: Double
    private var mapping: CaptureMapping?
    private weak var currentWindow: NSWindow?
    private var appliedMapping: CaptureMapping?
    private var appliedFrameRate: Int?
    private(set) var envelope: CGRect?
    private(set) var frameRate = 15
    private let forceAccessDenied: Bool
    var hasScreenAccess: Bool { !forceAccessDenied && CGPreflightScreenCaptureAccess() }
    private(set) var startAttempts = 0
    var needsStop: Bool { stream != nil || state == "starting" }

    init(sigma: Double = 12, forceAccessDenied: Bool = false) {
        Self.initializationCount += 1
        self.sigma = sigma
        self.forceAccessDenied = forceAccessDenied
        super.init()
    }

    func start(for window: NSWindow) async {
        guard stream == nil else { return }
        startAttempts += 1
        errorDescription = nil
        guard DesktopAvailability.blockers(for: window.screen).isEmpty else {
            state = "desktop_unavailable"
            return
        }
        guard !forceAccessDenied, CGPreflightScreenCaptureAccess() else {
            state = "permission_required"
            return
        }
        generation += 1
        currentWindow = window
        let ticket = generation
        state = "starting"
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard ticket == generation else { return }
            guard let screen = window.screen,
                  let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
                  let display = content.displays.first(where: { $0.displayID == id }),
                  let ownApplication = content.applications.first(where: { $0.processID == ProcessInfo.processInfo.processIdentifier }) else {
                throw OptionError.invalid("Cannot bind display and exclude the current application")
            }
            let filter = SCContentFilter(display: display, excludingApplications: [ownApplication], exceptingWindows: [])
            let configuration = try configuration(for: window, screen: screen)
            appliedMapping = mapping
            appliedFrameRate = frameRate
            let capture = SCStream(filter: filter, configuration: configuration, delegate: self)
            try capture.addStreamOutput(output, type: .screen, sampleHandlerQueue: queue)
            stream = capture
            displayID = id
            if let mapping { output.setMapping(mapping) }
            try await capture.startCapture()
            guard ticket == generation else {
                try? await capture.stopCapture()
                return
            }
            state = "capturing"
            requestGeometryUpdate(for: window)
        } catch {
            guard ticket == generation else { return }
            errorDescription = String(describing: error)
            await stop()
            state = "failed"
        }
    }

    func requestGeometryUpdate(for window: NSWindow) {
        pendingWindow = window
        guard stream != nil, state == "capturing", !updating else { return }
        updating = true
        let ticket = generation
        Task { @MainActor in
            defer {
                self.updating = false
                // A restore can enqueue a new stream's geometry while an old
                // updateConfiguration call is still completing. Drain that intent.
                if let pending = self.pendingWindow, self.state == "capturing", self.stream != nil {
                    self.requestGeometryUpdate(for: pending)
                }
            }
            while let window = self.pendingWindow, let capture = self.stream {
                self.pendingWindow = nil
                do {
                    guard let screen = window.screen else { throw OptionError.invalid("No connected capture display") }
                    guard self.isBound(to: screen) else { self.state = "rebind_required"; return }
                    let configuration = try self.configuration(for: window, screen: screen)
                    let mapping = self.mapping
                    let rate = self.frameRate
                    let geometryChanged = mapping != self.appliedMapping
                    if !geometryChanged, rate == self.appliedFrameRate {
                        if let mapping { self.output.resumeMappingIfNeeded(mapping) }
                        continue
                    }
                    if geometryChanged { self.output.setAccepting(false, preserveFrame: true) }
                    try await capture.updateConfiguration(configuration)
                    guard ticket == self.generation else { return }
                    self.appliedMapping = mapping
                    self.appliedFrameRate = rate
                    if geometryChanged, self.pendingWindow == nil, let mapping { self.output.setMapping(mapping) }
                } catch {
                    guard ticket == self.generation else { return }
                    self.errorDescription = String(describing: error)
                    await self.stop()
                    self.state = "failed"
                    return
                }
            }
        }
    }

    private func configuration(for window: NSWindow, screen: NSScreen) throws -> SCStreamConfiguration {
        let sampledFrame = envelope ?? window.glassFrame
        let region = try CaptureRegion(glassFrame: sampledFrame, displayFrame: screen.frame, backingScale: screen.backingScaleFactor, sigmaPixels: sigma)
        sourceRect = region.sourceRect
        mapping = CaptureMapping(glassFrame: sampledFrame, displayFrame: screen.frame, sourceRect: region.sourceRect,
                                 scale: screen.backingScaleFactor, width: region.pixelWidth, height: region.pixelHeight, sigma: sigma)
        let result = SCStreamConfiguration()
        result.sourceRect = region.sourceRect
        result.width = region.pixelWidth
        result.height = region.pixelHeight
        result.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        result.queueDepth = 3
        result.showsCursor = false
        result.capturesAudio = false
        result.pixelFormat = kCVPixelFormatType_32BGRA
        result.colorSpaceName = CGColorSpace.sRGB
        return result
    }

    func suspendFramesAndPendingStart() {
        generation += 1
        output.setAccepting(false)
    }

    func stop() async {
        generation += 1
        pendingWindow = nil
        let current = stream
        stream = nil
        displayID = nil
        appliedMapping = nil
        appliedFrameRate = nil
        output.setAccepting(false)
        if let current {
            do { try await current.stopCapture() }
            catch {
                let failure = error as NSError
                if failure.domain != SCStreamErrorDomain || failure.code != SCStreamError.Code.attemptToStopStreamState.rawValue {
                    errorDescription = String(describing: error)
                }
            }
        }
        state = "stopped"
    }

    func snapshot() -> [String: Any] {
        var result = output.snapshot()
        result["state"] = state
        result["error"] = errorDescription ?? ""
        result["source_rect_pt"] = NSStringFromRect(sourceRect)
        result["queue_depth"] = 3
        result["cursor_enabled"] = false
        result["audio_enabled"] = false
        result["capture_start_attempts"] = startAttempts
        result["permission_check_source"] = forceAccessDenied ? "injected_denial" : "system_preflight"
        result["bound_display_id"] = displayID ?? 0
        result["bound_backing_scale"] = mapping?.scale ?? 0
        result["target_capture_fps"] = frameRate
        return result
    }

    func writeLatestPNG(to url: URL) throws { try output.writeLatestPNG(to: url) }
    func writePNG(buffer: CVPixelBuffer, to url: URL) throws { try LatestCaptureOutput.writePNG(buffer: buffer, to: url) }
    func latestBuffer() -> CVPixelBuffer? { output.latestBuffer() }
    func requestNextValidFrame() { output.requestNextValidFrame() }

    func latestFrame() -> CapturedFrame? { output.latestFrame(acknowledge: true) }
    func setFrameHandler(_ handler: (@Sendable () -> Void)?) { output.setHandler(handler) }
    func setStateHandler(_ handler: @escaping () -> Void) { stateHandler = handler }
    var frameIssue: String? { output.frameIssue }

    func isBound(to screen: NSScreen) -> Bool {
        state == "capturing" && displayID == (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            && mapping?.scale == screen.backingScaleFactor && mapping?.displayFrame == screen.frame
    }

    // Explicit finite development probes only; never enabled by normal startup.
    func overrideStatusForTesting(_ value: String?) {
        let statuses: [String: SCFrameStatus] = ["blank": .blank, "suspended": .suspended, "stopped": .stopped]
        output.overrideStatusForTesting(value.flatMap { statuses[$0] })
    }

    func interruptForTesting() async {
        await stop()
        errorDescription = "Injected stream interruption"
        state = "failed"
    }

    func requestRebindForTesting() { state = "rebind_required" }

    func setFrameRate(_ value: Int) {
        guard value != frameRate, [10, 15, 30].contains(value) else { return }
        frameRate = value
        if let currentWindow { requestGeometryUpdate(for: currentWindow) }
    }

    func setSigma(_ value: Double) {
        guard value != sigma else { return }
        sigma = value
        output.setAccepting(false)
        if let currentWindow { requestGeometryUpdate(for: currentWindow) }
    }

    func setEnvelope(_ value: CGRect?) {
        guard value != envelope else { return }
        envelope = value
        if let currentWindow { requestGeometryUpdate(for: currentWindow) }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            guard self.stream === stream else { return }
            self.stream = nil
            self.output.setAccepting(false)
            self.state = "failed"
            self.errorDescription = String(describing: error)
        }
    }
}
