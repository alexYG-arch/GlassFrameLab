import Foundation

final class RenderMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [(Double, Double, Double, Int)] = []
    private var dropped = 0
    var droppedRecords: Int {
        lock.lock(); defer { lock.unlock() }
        return dropped
    }

    func record(presented: Double, captured: Double, gpuMilliseconds: Double, sequence: Int) {
        lock.lock()
        if records.count < 256 { records.append((presented, captured, gpuMilliseconds, sequence)) }
        else { dropped += 1 }
        lock.unlock()
    }

    func drain() -> [(Double, Double, Double, Int)] {
        lock.lock()
        defer { lock.unlock() }
        let values = records
        records.removeAll(keepingCapacity: true)
        return values
    }
}

/// Presentation and GPU completion can arrive in either order on different queues.
final class FramePresentationReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private let metrics: RenderMetrics
    private let captured: Double
    private let sequence: Int
    private var gpu: Double?
    private var time: Double?
    private var published = false

    init(metrics: RenderMetrics, captured: Double, sequence: Int) {
        self.metrics = metrics
        self.captured = captured
        self.sequence = sequence
    }

    func presented(at time: Double) {
        lock.lock(); defer { lock.unlock() }
        self.time = time
        publishIfComplete()
    }

    func completed(gpuMilliseconds: Double) {
        lock.lock(); defer { lock.unlock() }
        gpu = gpuMilliseconds
        publishIfComplete()
    }

    private func publishIfComplete() {
        guard !published, let gpu, let time else { return }
        published = true
        metrics.record(presented: time, captured: captured, gpuMilliseconds: gpu, sequence: sequence)
    }
}
