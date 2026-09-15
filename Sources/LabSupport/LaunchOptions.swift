import Foundation

public enum MaterialBackend: String { case custom, system }

public struct LaunchOptions {
    public var materialBackend: MaterialBackend = .custom
    public var testAppearance: String?
    public var testPermissionStatus = false
    public var testStaticFlow = false
    public var baseline = false
    public var animate = false
    public var calibration = false
    public var windowProbe = false
    public var geometryProbe = false
    public var captureProbe = false
    public var glassPreview = false
    public var foregroundProbe = false
    public var adaptiveMaterial = true
    public var borderFlow = BorderFlowStyle()
    public var upgradeProbe = false
    public var flowPhase = 0.3
    public var style = GlassStyle()
    public var sigma: Double { get { style.sigma } set { style.sigma = newValue } }
    public var styleProbe = false
    public var motionProbe = false
    public var motionPerformance = false
    public var resizePerformance = false
    public var frameCarrier = false
    public var runtimeProbe = false
    public var compatibilityProbe = false
    public var forcePermissionDenied = false
    public var forceMetalUnavailable = false
    public var permissionPrompt = true
    public var testCorner = false
    public var realtime: Bool { !baseline && !calibration && !frameCarrier && !windowProbe && !geometryProbe && !captureProbe && !glassPreview }
    public var widthPixels = 800.0
    public var heightPixels = 100.0
    public var duration: Double?
    public var output: URL?

    public init(arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--material-backend":
                index += 1
                guard index < arguments.count, let backend = MaterialBackend(rawValue: arguments[index]) else {
                    throw OptionError.invalid("--material-backend requires custom|system")
                }
                materialBackend = backend
            case "--test-appearance":
                index += 1
                guard index < arguments.count, ["light", "dark"].contains(arguments[index]) else {
                    throw OptionError.invalid("--test-appearance requires light|dark")
                }
                testAppearance = arguments[index]
            case "--test-permission-status": testPermissionStatus = true
            case "--test-static-flow": testStaticFlow = true
            case "--baseline": baseline = true
            case "--animate": animate = true
            case "--calibration": calibration = true
            case "--window-probe": windowProbe = true
            case "--geometry-probe": geometryProbe = true
            case "--capture-probe": captureProbe = true
            case "--glass-preview": glassPreview = true
            case "--foreground-probe": foregroundProbe = true
            case "--frame-carrier": frameCarrier = true
            case "--runtime-probe": runtimeProbe = true
            case "--compatibility-probe": compatibilityProbe = true
            case "--test-permission-denied": forcePermissionDenied = true
            case "--test-metal-unavailable": forceMetalUnavailable = true
            case "--no-permission-prompt": permissionPrompt = false
            case "--test-corner": testCorner = true
            case "--style-probe": styleProbe = true
            case "--motion-probe": motionProbe = true
            case "--motion-performance": motionPerformance = true
            case "--resize-performance": motionPerformance = true; resizePerformance = true
            case "--no-adaptive-material": adaptiveMaterial = false
            case "--border-flow": borderFlow.enabled = true
            case "--flow-once": borderFlow.enabled = true; borderFlow.mode = .once
            case "--upgrade-probe": upgradeProbe = true
            case "--flow-phase":
                index += 1
                guard index < arguments.count, let value = Double(arguments[index]), value.isFinite, (0...1).contains(value) else {
                    throw OptionError.invalid("--flow-phase requires 0...1")
                }
                flowPhase = value
            case "--flow-style":
                index += 1
                guard index < arguments.count else { throw OptionError.invalid("--flow-style requires JSON") }
                let data = try Data(contentsOf: URL(fileURLWithPath: arguments[index]))
                guard data.count <= 65536 else { throw OptionError.invalid("Flow JSON is too large") }
                borderFlow = try JSONDecoder().decode(BorderFlowStyle.self, from: data).validated()
            case "--no-outer-glow": style.shadowOpacity = 0
            case "--no-inner-glow": style.innerStrength = 0; style.innerShade = 0
            case "--no-edge": style.strokeOpacity = 0
            case "--style":
                index += 1
                guard index < arguments.count else { throw OptionError.invalid("--style requires a JSON file") }
                let data = try Data(contentsOf: URL(fileURLWithPath: arguments[index]))
                guard data.count <= 65536 else { throw OptionError.invalid("Style JSON is too large") }
                style = try JSONDecoder().decode(GlassStyle.self, from: data).validated()
            case "--sigma":
                index += 1
                guard index < arguments.count, let value = Double(arguments[index]), value.isFinite, value >= 0, value <= 40 else {
                    throw OptionError.invalid("--sigma requires sampling pixels in 0...40")
                }
                sigma = value
            case "--width-px", "--height-px":
                let key = arguments[index]
                index += 1
                guard index < arguments.count, let value = Double(arguments[index]) else {
                    throw OptionError.invalid("\(key) requires a numeric pixel value")
                }
                if key == "--width-px" { widthPixels = value } else { heightPixels = value }
            case "--duration":
                index += 1
                guard index < arguments.count, let value = Double(arguments[index]),
                      value.isFinite, value > 0 else {
                    throw OptionError.invalid("--duration requires a positive number of seconds")
                }
                duration = value
            case "--output":
                index += 1
                guard index < arguments.count, !arguments[index].hasPrefix("--") else {
                    throw OptionError.invalid("--output requires a directory")
                }
                output = URL(fileURLWithPath: arguments[index], isDirectory: true)
            default: throw OptionError.invalid("Unknown option: \(arguments[index])")
            }
            index += 1
        }
        if animate { calibration = true }
        if baseline && calibration {
            throw OptionError.invalid("--baseline cannot be combined with --animate or --calibration")
        }
        if windowProbe && (baseline || calibration) {
            throw OptionError.invalid("--window-probe requires the default frame mode")
        }
        if geometryProbe && (windowProbe || baseline || calibration) {
            throw OptionError.invalid("--geometry-probe requires the default frame mode")
        }
        if captureProbe && (windowProbe || baseline || calibration) {
            throw OptionError.invalid("--capture-probe requires the default frame mode")
        }
        if glassPreview && (captureProbe || windowProbe || geometryProbe || baseline || calibration) {
            throw OptionError.invalid("--glass-preview requires the default frame mode without other probes")
        }
        if foregroundProbe && !glassPreview {
            throw OptionError.invalid("--foreground-probe requires --glass-preview")
        }
        if runtimeProbe && !realtime { throw OptionError.invalid("--runtime-probe requires realtime frame mode") }
        if styleProbe && !realtime { throw OptionError.invalid("--style-probe requires realtime frame mode") }
        if motionPerformance && (!realtime || duration == nil || motionProbe || runtimeProbe || styleProbe) { throw OptionError.invalid("--motion-performance requires a finite realtime run without other probes") }
        if motionProbe && !realtime { throw OptionError.invalid("--motion-probe requires realtime frame mode") }
        if compatibilityProbe && (!realtime || (duration ?? 0) < 30 || runtimeProbe || styleProbe || motionProbe || motionPerformance) {
            throw OptionError.invalid("--compatibility-probe requires a realtime run of at least 30 seconds without other probes")
        }
        if forcePermissionDenied && (!realtime || duration == nil) {
            throw OptionError.invalid("--test-permission-denied requires a finite realtime run")
        }
        if forceMetalUnavailable && (!realtime || duration == nil || compatibilityProbe || forcePermissionDenied) {
            throw OptionError.invalid("--test-metal-unavailable requires a finite isolated realtime run")
        }
        if materialBackend == .system && (!realtime || runtimeProbe || styleProbe || motionPerformance || compatibilityProbe || forcePermissionDenied || !adaptiveMaterial) {
            throw OptionError.invalid("system backend requires realtime mode; capture/legacy material probes are incompatible")
        }
        if (testAppearance != nil || testPermissionStatus || testStaticFlow) && (materialBackend != .system || duration == nil) {
            throw OptionError.invalid("System test options require an explicit system backend and finite duration")
        }
        if testStaticFlow && !borderFlow.enabled { throw OptionError.invalid("--test-static-flow requires enabled flow") }
        borderFlow = try borderFlow.validated()
        if upgradeProbe && (!realtime || (duration ?? 0) < 85 || runtimeProbe || styleProbe || motionProbe || motionPerformance || compatibilityProbe) {
            throw OptionError.invalid("--upgrade-probe requires an isolated realtime run of at least 85 seconds")
        }
        style = try style.validated()
        if frameCarrier && (baseline || calibration || windowProbe || geometryProbe || captureProbe || glassPreview) {
            throw OptionError.invalid("--frame-carrier cannot be combined with other modes")
        }
    }
}

public enum OptionError: Error, CustomStringConvertible {
    case invalid(String)
    public var description: String {
        switch self { case .invalid(let message): return message }
    }
}
