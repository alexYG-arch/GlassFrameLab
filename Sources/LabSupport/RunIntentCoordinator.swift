import Foundation

/// Serializes asynchronous start/stop operations while retaining the newest intent.
@MainActor public final class RunIntentCoordinator {
    public private(set) var desiredRunning = false
    private var revision = 0
    private var pendingStop = false
    private var worker: Task<Void, Never>?
    private let start: () async -> Void
    private let stop: () async -> Void
    private let suspend: () -> Void

    public init(start: @escaping () async -> Void, stop: @escaping () async -> Void,
                suspend: @escaping () -> Void) {
        self.start = start
        self.stop = stop
        self.suspend = suspend
    }

    public func request(_ running: Bool) {
        if desiredRunning != running { revision += 1 }
        desiredRunning = running
        if !running { pendingStop = true; suspend() }
        guard worker == nil else { return }
        worker = Task { @MainActor in
            while true {
                if self.pendingStop || !self.desiredRunning {
                    self.pendingStop = false
                    await self.stop()
                    if !self.desiredRunning && !self.pendingStop { break }
                    continue
                }
                let ticket = self.revision
                await self.start()
                if ticket == self.revision && !self.pendingStop { break }
            }
            self.worker = nil
        }
    }

    public func waitUntilSettled() async {
        while let worker { await worker.value }
    }
}
