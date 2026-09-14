import Foundation
import CoreGraphics
import LabSupport

enum CheckFailure: Error { case failed(String) }
func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure.failed(message) }
}
func expectInvalid(_ arguments: [String]) throws {
    do { _ = try LaunchOptions(arguments: arguments) }
    catch is OptionError { return }
    throw CheckFailure.failed("Expected invalid options: \(arguments)")
}

let checks: [(String, () throws -> Void)] = [
    ("flow freezes active time and resumes without catch-up", {
        var clock = BorderFlowClock()
        clock.setRunning(true, at: 10)
        clock.setRunning(false, at: 12)
        try expect(abs(clock.phase(at: 100, period: 7) - 2.0/7) < 1e-9, "Frozen phase advanced")
        clock.setRunning(false, at: 101)
        clock.setRunning(true, at: 200)
        try expect(abs(clock.phase(at: 201, period: 7) - 3.0/7) < 1e-9, "Resume caught up wall clock")
        var style = BorderFlowStyle(); style.mode = .once
        try expect(!clock.finished(at: 201, style: style), "Freeze consumed one-shot time")
        try expect(clock.finished(at: 205, style: style), "One-shot never completed")
        clock.reset()
        try expect(clock.phase(at: 1000, period: 7) == 0 && !clock.isRunning, "Reset retained phase")
    }),
    ("legacy glass decoding and independent flow configuration", {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(GlassStyle())) as! [String: Any]
        json.removeValue(forKey: "strokeColor")
        let old = try JSONDecoder().decode(GlassStyle.self, from: JSONSerialization.data(withJSONObject: json))
        try expect(old.strokeColor == [1,1,1], "Old style lost white edge")
        let options = try LaunchOptions(arguments: ["--border-flow", "--no-adaptive-material"])
        try expect(options.borderFlow.enabled && !options.adaptiveMaterial, "Independent switches lost")
        try expect(options.style == GlassStyle(), "Flow changed base style")
        var flow = BorderFlowStyle(); flow.period = .nan
        do { _ = try flow.validated(); throw CheckFailure.failed("Invalid flow accepted") } catch is OptionError {}
    }),
    ("render cadence does not accumulate dispatch lateness", {
        var cadence = RenderCadence()
        try expect(cadence.delay(now: 100, frameRate: 30) == 0, "First frame delayed")
        cadence.didSubmit(at: 100)
        for index in 1...300 {
            let arrival = 100 + Double(index) / 30 + 0.002
            try expect(cadence.delay(now: arrival, frameRate: 30) == 0, "Dispatch lateness accumulated")
            cadence.didSubmit(at: arrival)
            let next = arrival + cadence.delay(now: arrival, frameRate: 30)
            try expect(abs(next - (100 + Double(index + 1) / 30)) < 0.000001, "Cadence phase drifted")
        }
    }),
    ("render cadence resumes after idle without catch-up submissions", {
        var cadence = RenderCadence()
        _ = cadence.delay(now: 100, frameRate: 30)
        cadence.didSubmit(at: 100)
        try expect(cadence.delay(now: 110, frameRate: 30) == 0, "Fresh frame after idle delayed")
        cadence.didSubmit(at: 110)
        try expect(abs(cadence.delay(now: 110, frameRate: 30) - 1.0/30) < 0.000001, "Overdue work can burst")
    }),
    ("render cadence follows reduced and restored capture rates", {
        var cadence = RenderCadence()
        _ = cadence.delay(now: 100, frameRate: 30)
        cadence.didSubmit(at: 100)
        try expect(abs(cadence.delay(now: 100, frameRate: 15) - 1.0/15) < 0.000001, "Reduced rate ignored")
        try expect(abs(cadence.delay(now: 100, frameRate: 30) - 1.0/30) < 0.000001, "Restored rate ignored")
    }),
    ("geometry rejects stale samples including after delayed GPU completion", {
        try expect(FrameFreshness.allowsGeometry(capturedAt: 100, now: 100.05), "Fresh capture rejected")
        try expect(!FrameFreshness.allowsGeometry(capturedAt: 100, now: 100.35), "Delayed old capture can commit geometry")
        try expect(FrameFreshness.allowsGeometry(capturedAt: 100.34, now: 100.35), "Fresh replacement cannot resume geometry")
        try expect(!FrameFreshness.allowsGeometry(capturedAt: .nan, now: 100), "Invalid capture clock accepted")
        try expect(!FrameFreshness.allowsGeometry(capturedAt: 101, now: 100), "Future capture clock accepted")
    }),
    ("compatibility injection is finite and isolated from unrelated probes", {
        try expectInvalid(["--compatibility-probe"])
        try expectInvalid(["--compatibility-probe", "--duration", "10"])
        try expectInvalid(["--compatibility-probe", "--duration", "32", "--motion-probe"])
        try expectInvalid(["--test-permission-denied"])
        try expectInvalid(["--test-metal-unavailable"])
        try expectInvalid(["--test-metal-unavailable", "--compatibility-probe", "--duration", "32"])
        try expectInvalid(["--test-permission-denied", "--duration", "32", "--baseline"])
        let probe = try LaunchOptions(arguments: ["--compatibility-probe", "--test-permission-denied", "--duration", "32"])
        try expect(probe.realtime && probe.compatibilityProbe && probe.forcePermissionDenied, "Explicit compatibility probe lost its mode")
    }),
    ("interrupted geometry transition preserves its presented anchor", {
        let start = CGRect(x: 100, y: 200, width: 412, height: 62)
        let target = CGRect(x: 0, y: 150, width: 612, height: 162)
        for p in stride(from: 0.0, through: 1, by: 0.05) {
            let frame = FrameGeometry.interpolate(from: start, to: target, progress: p)
            try expect(abs(frame.midX-start.midX)<0.000001 && abs(frame.midY-start.midY)<0.000001, "Transition moved the shared center")
            try expect(frame.width>=start.width && frame.width<=target.width, "Transition overshot size")
        }
        let interrupted = FrameGeometry.interpolate(from: start, to: target, progress: 0.4)
        try expect(FrameGeometry.interpolate(from: interrupted, to: start, progress: 0)==interrupted, "Interrupted animation jumped to original start")
        try expect(FrameGeometry.interpolate(from: interrupted, to: start, progress: 1)==start, "New animation missed its final geometry")
        try expectInvalid(["--motion-probe", "--glass-preview"])
        try expectInvalid(["--motion-performance"])
        try expectInvalid(["--motion-performance", "--duration", "10", "--baseline"])
        try expectInvalid(["--motion-performance", "--duration", "10", "--motion-probe"])
    }),
    ("glass style validates bounds and independent effect switches", {
        var invalid = GlassStyle(); invalid.shadowExtent = .nan
        do { _ = try invalid.validated(); throw CheckFailure.failed("Accepted NaN extent") } catch is OptionError {}
        invalid = GlassStyle(); invalid.lightDirection = [0,0]
        do { _ = try invalid.validated(); throw CheckFailure.failed("Accepted zero direction") } catch is OptionError {}
        invalid = GlassStyle(); invalid.tintColor = [1]
        do { _ = try invalid.validated(); throw CheckFailure.failed("Accepted invalid color") } catch is OptionError {}
        let off = try LaunchOptions(arguments: ["--no-outer-glow","--no-inner-glow","--no-edge"])
        try expect(off.style.shadowOpacity == 0 && off.style.innerStrength == 0 && off.style.innerShade == 0 && off.style.strokeOpacity == 0, "Layer switches must remain independent")
        try expect(off.style.shadowExtent == 6 && off.sigma == 12, "Layer switches changed sampling or drawable envelope")
        try expectInvalid(["--style-probe", "--glass-preview"])
    }),
    ("shadow insets preserve glass pixels and local sampling", {
        let screen = CGRect(x: 0, y: 54, width: 1512, height: 895)
        let value = try FrameGeometry.resolve(requested: .minimum, backingScale: 2, visibleFrame: screen, currentFrame: nil, shadowInset: 6)
        try expect(value.actualPixels == CGSize(width: 800, height: 100), "Shadow must not consume the glass body")
        try expect(value.frame.size == CGSize(width: 412, height: 62), "Incorrect panel envelope")
        try expect(value.glassFrame.midX == screen.midX && value.glassFrame.midY == screen.midY, "Shadow moved the center")
        let region = try CaptureRegion(glassFrame: value.glassFrame, displayFrame: CGRect(x: 0,y: 0,width: 1512,height: 982), backingScale: 2)
        try expect(region.pixelWidth == 472 && region.pixelHeight == 122, "Shadow enlarged capture")
        let huge = try FrameGeometry.resolve(requested: FramePixelSize(width: 10000, height: 10000), backingScale: 2, visibleFrame: screen, currentFrame: value.frame, shadowInset: 6)
        try expect(huge.frame.width == 1464 && huge.frame.height == 716 && huge.actualPixels == CGSize(width: 2904, height: 1408), "Maximum includes outer padding")
        let narrow = try FrameGeometry.resolve(requested: .minimum, backingScale: 2, visibleFrame: CGRect(x: -400,y: 0,width: 400,height: 100), currentFrame: nil, shadowInset: 6)
        try expect(narrow.sizeLimited && narrow.frame.minX >= -376 && narrow.frame.maxX <= -24 && narrow.glassFrame.width == 340, "Padded panel escaped narrow screen")
    }),
    ("realtime is default and diagnostic carrier is explicit", {
        let normal = try LaunchOptions(arguments: [])
        try expect(normal.realtime, "Default must render realtime glass")
        let carrier = try LaunchOptions(arguments: ["--frame-carrier"])
        try expect(!carrier.realtime, "Carrier must not capture")
        try expectInvalid(["--frame-carrier", "--glass-preview"])
        try expectInvalid(["--runtime-probe", "--baseline"])
    }),
    ("glass preview bounds sigma and separates test modes", {
        for value in ["nan", "inf", "-1", "41", "bad"] { try expectInvalid(["--glass-preview", "--sigma", value]) }
        try expectInvalid(["--foreground-probe"])
        try expectInvalid(["--glass-preview", "--capture-probe"])
        try expectInvalid(["--glass-preview", "--baseline"])
        let preview = try LaunchOptions(arguments: ["--glass-preview", "--sigma", "0", "--foreground-probe"])
        try expect(preview.glassPreview && preview.sigma == 0 && preview.foregroundProbe, "Single-frame mode lost explicit parameters")
    }),
    ("capture region crops locally with point/pixel conversion", {
        let region = try CaptureRegion(glassFrame: CGRect(x: 500,y: 400,width: 400,height: 50), displayFrame: CGRect(x: 0,y: 0,width: 1512,height: 982), backingScale: 2)
        try expect(region.pixelWidth == 472 && region.pixelHeight == 122, "Expected local 0.5x output with 36pt margin")
        try expect(region.sourceRect.origin == CGPoint(x: 464,y: 496), "Wrong display-local flipped source origin")
        let edge = try CaptureRegion(glassFrame: CGRect(x: -1000,y: 0,width: 400,height: 50), displayFrame: CGRect(x: -1000,y: 0,width: 1000,height: 500), backingScale: 1)
        try expect(edge.sourceRect.minX == 0 && edge.sourceRect.maxY == 500, "Edge crop escaped display")
        try expect(edge.pixelWidth == 236 && edge.pixelHeight == 61, "Wrong edge-cropped output scale")
    }),
    ("geometry grows and shrinks around the current center", {
        let screen = CGRect(x: 0, y: 54, width: 1512, height: 895)
        let initial = try FrameGeometry.resolve(requested: .minimum, backingScale: 2, visibleFrame: screen, currentFrame: nil)
        let grown = try FrameGeometry.resolve(requested: FramePixelSize(width: 1600, height: 300), backingScale: 2, visibleFrame: screen, currentFrame: initial.frame)
        try expect(grown.frame.size == CGSize(width: 800, height: 150), "Wrong pixel conversion")
        try expect(grown.frame.midX == initial.frame.midX && grown.frame.midY == initial.frame.midY, "Center moved")
        let shrunk = try FrameGeometry.resolve(requested: .minimum, backingScale: 2, visibleFrame: screen, currentFrame: grown.frame)
        try expect(shrunk.frame == initial.frame, "Shrink did not restore the minimum")
    }),
    ("screen boundary wins over minimum and edge anchor", {
        let screen = CGRect(x: -400, y: 0, width: 400, height: 500)
        let value = try FrameGeometry.resolve(requested: .minimum, backingScale: 2, visibleFrame: screen, currentFrame: CGRect(x: -5, y: 490, width: 400, height: 50))
        try expect(value.sizeLimited && value.actualPixels.width == 704, "Narrow screen must reduce minimum")
        try expect(value.frame.minX == -376 && value.frame.maxX == -24 && value.frame.maxY <= 500, "Window escaped visible bounds")
    }),
    ("oversized and invalid inputs have explicit outcomes", {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let huge = try FrameGeometry.resolve(requested: FramePixelSize(width: 10000, height: 10000), backingScale: 2, visibleFrame: screen, currentFrame: nil)
        try expect(huge.frame.size == CGSize(width: 952, height: 400) && huge.sizeLimited, "Maximum cap mismatch")
        let invalid = try FrameGeometry.resolve(requested: FramePixelSize(width: .nan, height: -1), backingScale: 2, visibleFrame: screen, currentFrame: nil)
        try expect(invalid.usedDefaultInput && invalid.actualPixels == CGSize(width: 800, height: 100), "Invalid inputs must report fallback")
    }),
    ("native fractional geometry agrees with integral window frame", {
        let screen = CGRect(x: 0, y: 54, width: 1512, height: 895)
        let value = try FrameGeometry.resolve(requested: FramePixelSize(width: 804.654982, height: 101.117196), backingScale: 2,
            visibleFrame: screen, currentFrame: CGRect(x: 178.836254-6, y: 718.720701-6, width: 414.327491, height: 62.558598),
            shadowInset: 6, alignToWindowPoints: true)
        try expect(value.frame.origin.x == floor(value.frame.origin.x) && value.frame.origin.y == floor(value.frame.origin.y), "Fractional native origin")
        try expect(value.actualPixels == CGSize(width: 806, height: 102), "Actual drawable must match normalized window dimensions")
        try expect(screen.contains(value.frame), "Alignment escaped screen")
    }),
    ("pixel contract stays 800 by 100 across display scales", {
        let retina = try FramePixelSize.minimum.points(backingScale: 2)
        let standard = try FramePixelSize.minimum.points(backingScale: 1)
        try expect(retina.width == 400 && retina.height == 50, "Retina must use 400x50 pt")
        try expect(standard.width == 800 && standard.height == 100, "1x must use 800x100 pt")
        do {
            _ = try FramePixelSize.minimum.points(backingScale: 0)
            throw CheckFailure.failed("Invalid scale must fail")
        } catch is OptionError { }
    }),
    ("calibration is explicit and excluded from baseline", {
        let defaultMode = try LaunchOptions(arguments: [])
        let calibration = try LaunchOptions(arguments: ["--calibration"])
        try expect(!defaultMode.calibration, "Default must be the borderless frame")
        try expect(calibration.calibration, "Calibration flag must select fixture")
        try expectInvalid(["--baseline", "--calibration"])
    }),
    ("baseline excludes animation", {
        try expectInvalid(["--baseline", "--animate"])
    }),
    ("invalid duration cannot become unbounded run", {
        for value in ["0", "-1", "nan", "inf", "text"] {
            try expectInvalid(["--duration", value])
        }
        try expectInvalid(["--duration"])
    }),
    ("output does not swallow flags and unknown flags fail", {
        try expectInvalid(["--output", "--baseline"])
        try expectInvalid(["--unknown"])
    }),
    ("valid run retains explicit values", {
        let options = try LaunchOptions(arguments: ["--animate", "--duration", "20", "--output", "/tmp/evidence"])
        try expect(options.animate && !options.baseline, "Wrong run mode")
        try expect(options.duration == 20, "Wrong duration")
        try expect(options.output?.path == "/tmp/evidence", "Wrong output")
    }),
    ("rate uses actual elapsed time and draws, then resets", {
        var meter = IntervalMeter(time: 10, cpuSeconds: 2)
        for _ in 0..<30 { meter.recordDraw() }
        let busy = meter.sample(time: 12, cpuSeconds: 2.5)
        try expect(busy.drawCallsPerSecond == 15, "Must divide draws by actual elapsed time")
        try expect(busy.cpuPercentOfOneCore == 25, "Wrong CPU normalization")
        try expect(busy.drawCalls == 30, "Wrong draw count")
        let idle = meter.sample(time: 13, cpuSeconds: 2.5)
        try expect(idle.drawCalls == 0 && idle.cpuPercentOfOneCore == 0, "Interval did not reset")
    })
]

var failures = 0
for (name, check) in checks {
    do { try check(); print("PASS \(name)") }
    catch { failures += 1; fputs("FAIL \(name): \(error)\n", stderr) }
}
print("\(checks.count - failures)/\(checks.count) checks passed")
exit(failures == 0 ? 0 : 1)
