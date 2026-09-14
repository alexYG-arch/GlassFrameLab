import Foundation

/// Independent from the base glass. Distances are points; colors are linear RGB.
public struct BorderFlowStyle: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable { case loop, once }
    public var enabled = false
    public var mode: Mode = .loop
    public var period = 7.0
    public var clockwise = true
    public var tailFraction = 0.20
    public var strength = 0.85
    public var innerGlowGain = 0.20
    public var innerShadeGain = 0.012
    public var spread = 10.0
    // Brand #3B78DD hue (217.4074 degrees), preserving the dark endpoint S/V.
    public var headColor: [Double] = [0.12, 0.33529803598359087, 1.0]
    public var tailColor: [Double] = [0.32, 0.025, 0.8]
    public init() {}

    public func validated() throws -> Self {
        let ranges: [(Double, ClosedRange<Double>)] = [(period, 1...60), (tailFraction, 0.02...0.5),
            (strength, 0...1), (innerGlowGain, 0...0.5), (innerShadeGain, 0...0.1), (spread, 1...20)]
        guard ranges.allSatisfy({ $0.0.isFinite && $0.1.contains($0.0) }),
              headColor.count == 3, tailColor.count == 3,
              (headColor + tailColor).allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw OptionError.invalid("Invalid border flow parameters")
        }
        return self
    }
}

/// Only active playback time advances phase. Geometry never owns this clock.
public struct BorderFlowClock: Sendable {
    private var accumulated = 0.0
    private var began: Double?
    public var isRunning: Bool { began != nil }
    public init() {}
    public mutating func reset() { accumulated = 0; began = nil }
    public mutating func setRunning(_ running: Bool, at now: Double) {
        if running, began == nil { began = now }
        if !running, let start = began { accumulated += max(0, now - start); began = nil }
    }
    public func elapsed(at now: Double) -> Double { accumulated + (began.map { max(0, now - $0) } ?? 0) }
    public func phase(at now: Double, period: Double) -> Double {
        (elapsed(at: now) / period).truncatingRemainder(dividingBy: 1)
    }
    public func finished(at now: Double, style: BorderFlowStyle) -> Bool {
        style.mode == .once && elapsed(at: now) >= style.period
    }
}
