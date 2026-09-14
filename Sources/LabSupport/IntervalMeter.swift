import Foundation

/// Counts actual view draw calls, never timer ticks or displayed GPU frames.
public struct IntervalMeter {
    private var previousTime: Double
    private var previousCPU: Double
    private var drawCount = 0

    public init(time: Double, cpuSeconds: Double) {
        previousTime = time
        previousCPU = cpuSeconds
    }

    public mutating func recordDraw() { drawCount += 1 }

    public mutating func sample(time: Double, cpuSeconds: Double) -> IntervalSample {
        let elapsed = time - previousTime
        let count = drawCount
        let result = IntervalSample(
            elapsedSeconds: elapsed,
            drawCalls: count,
            drawCallsPerSecond: elapsed > 0 ? Double(count) / elapsed : 0,
            cpuPercentOfOneCore: elapsed > 0 ? max(0, cpuSeconds - previousCPU) / elapsed * 100 : 0
        )
        previousTime = time
        previousCPU = cpuSeconds
        drawCount = 0
        return result
    }
}

public struct IntervalSample {
    public let elapsedSeconds: Double
    public let drawCalls: Int
    public let drawCallsPerSecond: Double
    public let cpuPercentOfOneCore: Double
}
