/// Demand-driven submission deadlines. This does not create a repeating timer.
public struct RenderCadence {
    private var interval = 0.0
    private var deadline: Double?
    private var lastSubmission: Double?

    public init() {}

    public mutating func delay(now: Double, frameRate: Int) -> Double {
        let requestedInterval = 1.0 / Double(frameRate)
        if requestedInterval != interval {
            interval = requestedInterval
            deadline = lastSubmission.map { $0 + interval }
        }
        return max(0, (deadline ?? now) - now)
    }

    public mutating func didSubmit(at now: Double) {
        // Keep the phase through small dispatch delays; after a missed period,
        // start here instead of submitting a burst of overdue work.
        let due = deadline ?? now
        deadline = now - due >= interval ? now + interval : due + interval
        lastSubmission = now
    }
}
