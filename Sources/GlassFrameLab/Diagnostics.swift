import AppKit
import Darwin
import LabSupport

final class Diagnostics {
    private let output: URL?
    private var samples: FileHandle?
    private var frames: FileHandle?
    private var runtimeSamples: FileHandle?
    let start = ProcessInfo.processInfo.systemUptime
    private var meter: IntervalMeter
    private(set) var sampleCount = 0

    init(output: URL?) throws {
        self.output = output
        meter = IntervalMeter(time: ProcessInfo.processInfo.systemUptime, cpuSeconds: try Self.cpuSeconds())
        if let output {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let url = output.appendingPathComponent("samples.csv")
            // A run must use a fresh evidence directory; never silently replace earlier evidence.
            guard !FileManager.default.fileExists(atPath: url.path) else {
                throw OptionError.invalid("Evidence already exists at \(url.path); choose a new directory")
            }
            try Data("elapsed_seconds,interval_seconds,resident_bytes,cpu_percent_one_core,draw_calls,draw_calls_per_second,window_visible,low_power,thermal_state\n".utf8).write(to: url)
            samples = try FileHandle(forWritingTo: url)
            try samples?.seekToEnd()
            let frameURL = output.appendingPathComponent("frames.csv")
            try Data("presented_seconds,captured_seconds,gpu_ms,sequence,latency_ms\n".utf8).write(to: frameURL)
            frames = try FileHandle(forWritingTo: frameURL)
            try frames?.seekToEnd()
            let runtimeURL = output.appendingPathComponent("runtime-samples.csv")
            try Data("elapsed_seconds,target_fps,captured,changed,submitted,in_flight,retained_buffers,texture_allocations\n".utf8).write(to: runtimeURL)
            runtimeSamples = try FileHandle(forWritingTo: runtimeURL)
            try runtimeSamples?.seekToEnd()
        }
    }

    func recordDraw() { meter.recordDraw() }

    func sample(windowVisible: Bool) throws {
        let now = ProcessInfo.processInfo.systemUptime
        let interval = meter.sample(time: now, cpuSeconds: try Self.cpuSeconds())
        guard let residentBytes = Self.residentBytes() else {
            throw OptionError.invalid("task_info could not read resident memory")
        }
        let resident = String(residentBytes)
        let line = String(format: "%.4f,%.4f,%@,%.4f,%d,%.4f,%d,%d,%d\n",
            now - start, interval.elapsedSeconds, resident, interval.cpuPercentOfOneCore,
            interval.drawCalls, interval.drawCallsPerSecond, windowVisible ? 1 : 0,
            ProcessInfo.processInfo.isLowPowerModeEnabled ? 1 : 0,
            ProcessInfo.processInfo.thermalState.rawValue)
        try samples?.write(contentsOf: Data(line.utf8))
        sampleCount += 1
    }

    func writeJSON(_ value: [String: Any], name: String) throws {
        guard let output else { return }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent(name), options: .atomic)
    }

    func finish() throws {
        try samples?.synchronize()
        try samples?.close()
        try frames?.synchronize()
        try frames?.close()
        try runtimeSamples?.synchronize()
        try runtimeSamples?.close()
    }

    func recordFrames(_ records: [(Double, Double, Double, Int)]) throws {
        guard !records.isEmpty else { return }
        let lines = records.map { record in
            let latency = record.0 > 0 && record.1 > 0 ? String(format: "%.5f", (record.0 - record.1) * 1000) : ""
            return String(format: "%.9f,%.9f,%.5f,%d,%@\n", record.0, record.1, record.2, record.3, latency)
        }.joined()
        try frames?.write(contentsOf: Data(lines.utf8))
    }

    func recordRuntime(_ values: [String: Any]) throws {
        let keys = ["target_capture_fps", "received_complete_frames", "changed_frames", "gpu_submissions", "gpu_in_flight", "retained_buffers", "texture_allocations"]
        let line = String(format: "%.4f,", ProcessInfo.processInfo.systemUptime - start) + keys.map { String(values[$0] as? Int ?? -1) }.joined(separator: ",") + "\n"
        try runtimeSamples?.write(contentsOf: Data(line.utf8))
    }

    static func cpuSeconds() throws -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else {
            throw OptionError.invalid("getrusage could not read process CPU time")
        }
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    static func residentBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : nil
    }

    static func environment(mode: String) -> [String: Any] {
        [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "mode": mode,
            "process_id": ProcessInfo.processInfo.processIdentifier,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "physical_memory_bytes": ProcessInfo.processInfo.physicalMemory,
            "low_power_mode": ProcessInfo.processInfo.isLowPowerModeEnabled,
            "screens": NSScreen.screens.map { screen -> [String: Any] in
                let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
                let mode = CGDisplayCopyDisplayMode(id)
                return [
                    "name": screen.localizedName,
                    "display_id": id,
                    "frame_pt": NSStringFromRect(screen.frame),
                    "visible_frame_pt": NSStringFromRect(screen.visibleFrame),
                    "backing_scale": screen.backingScaleFactor,
                    "display_mode_pixel_width": mode.map { $0.pixelWidth as Any } ?? NSNull(),
                    "display_mode_pixel_height": mode.map { $0.pixelHeight as Any } ?? NSNull(),
                    "backing_width_px": screen.frame.width * screen.backingScaleFactor,
                    "backing_height_px": screen.frame.height * screen.backingScaleFactor
                ]
            },
            "measurement_notes": [
                "resident_bytes is task resident memory, not physical footprint or GPU allocation",
                "draw_calls_per_second is NSView draw invocations, not display presentation FPS",
                "cpu_percent_one_core uses process user+system CPU time; 100 means one CPU core",
                "No screen capture, glass shader, GPU timing, or watt measurement in WP-00"
            ]
        ]
    }
}
