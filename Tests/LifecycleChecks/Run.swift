import Foundation
import LabSupport

@MainActor final class Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

@MainActor final class DelayedCapture {
    var events: [String] = []
    var running = false
    var accepting = false
    var starts = 0
    var startRelease: Gate?
    var stopRelease: Gate?
    let startEntered = Gate()
    let stopEntered = Gate()
    lazy var coordinator = RunIntentCoordinator(start: { [unowned self] in
        events.append("start")
        starts += 1
        startEntered.open()
        let gate = startRelease
        startRelease = nil
        await gate?.wait()
        running = true
        accepting = true
    }, stop: { [unowned self] in
        events.append("stop")
        stopEntered.open()
        let gate = stopRelease
        stopRelease = nil
        await gate?.wait()
        running = false
        accepting = false
    }, suspend: { [unowned self] in accepting = false })
}

@main struct LifecycleChecks {
    @MainActor static func main() async {
        func check(_ value: Bool, _ label: String) {
            guard value else { fputs("FAIL \(label)\n", stderr); exit(1) }
            print("PASS \(label)")
        }
        let a = DelayedCapture(), startup = Gate()
        a.startRelease = startup
        a.coordinator.request(true)
        await a.startEntered.wait()
        a.coordinator.request(false)
        check(!a.accepting, "hide immediately gates frame acceptance")
        a.coordinator.request(true)
        startup.open()
        await a.coordinator.waitUntilSettled()
        check(a.running && a.starts == 2 && a.events == ["start", "stop", "start"],
              "hide and restore during startup drains old start then starts newest intent")

        let b = DelayedCapture()
        b.coordinator.request(true)
        await b.coordinator.waitUntilSettled()
        let stopping = Gate()
        b.stopRelease = stopping
        b.coordinator.request(false)
        await b.stopEntered.wait()
        b.coordinator.request(true)
        b.coordinator.request(true)
        stopping.open()
        await b.coordinator.waitUntilSettled()
        check(b.running && b.starts == 2 && b.events.last == "start", "restore during stop survives late stop completion")

        b.coordinator.request(false)
        b.coordinator.request(true)
        await b.coordinator.waitUntilSettled()
        check(b.running && b.accepting && b.starts == 3, "same-turn hide and restore must drain the suspended stream")

        let c = DelayedCapture(), finalStop = Gate()
        c.startRelease = finalStop
        c.coordinator.request(true)
        await c.startEntered.wait()
        c.coordinator.request(false)
        c.coordinator.request(true)
        c.coordinator.request(false)
        finalStop.open()
        await c.coordinator.waitUntilSettled()
        check(!c.running && !c.accepting && c.starts == 1, "final hidden intent wins interrupted startup")

        for _ in 0..<20 {
            c.coordinator.request(true)
            await c.coordinator.waitUntilSettled()
            c.coordinator.request(false)
            await c.coordinator.waitUntilSettled()
        }
        check(c.starts == 21 && !c.running && !c.accepting, "twenty serial restores end fully stopped")
        print("6/6 lifecycle checks passed")
    }
}
