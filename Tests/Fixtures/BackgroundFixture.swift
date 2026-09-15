import AppKit

final class Pattern: NSView {
    var phase = 0.0
    var backdrop = "pattern"
    override func mouseDown(with event: NSEvent) {
        print("FIXTURE_CLICK \(event.locationInWindow)")
        fflush(stdout)
    }
    override func draw(_ dirtyRect: NSRect) {
        if backdrop == "light-detail" || backdrop == "dark-detail-icons" {
            let light = backdrop == "light-detail"
            (light ? NSColor.white : NSColor(srgbRed: 0.075, green: 0.09, blue: 0.12, alpha: 1)).setFill()
            bounds.fill()
            let colors: [NSColor] = [.systemBlue, .systemPurple, .systemOrange, .systemTeal]
            for i in 0..<5 {
                let x = bounds.midX - 195 + CGFloat(i) * 85
                colors[i % 4].setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: bounds.midY - 12, width: 32, height: 32), xRadius: 4, yRadius: 4).fill()
                ("Photo 0\(i + 1)" as NSString).draw(at: NSPoint(x: x - 5, y: bounds.midY - 28),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: light ? NSColor.black : NSColor.white])
            }
            return
        }
        let solids: [String: NSColor] = [
            "black": .black,
            "deepgray": NSColor(srgbRed: 0.2, green: 0.2, blue: 0.2, alpha: 1),
            "white": .white,
            "gray": NSColor(srgbRed: 0.95, green: 0.95, blue: 0.95, alpha: 1),
            "warm": NSColor(srgbRed: 0.98, green: 0.94, blue: 0.88, alpha: 1),
            "cool": NSColor(srgbRed: 0.88, green: 0.95, blue: 0.99, alpha: 1),
            "dark": NSColor(srgbRed: 0.075, green: 0.09, blue: 0.12, alpha: 1)
        ]
        if let color = solids[backdrop] {
            color.setFill(); bounds.fill(); return
        }
        if ["dark-detail", "mixed", "checker", "narrow"].contains(backdrop) {
            NSColor(srgbRed: 0.04, green: 0.06, blue: 0.09, alpha: 1).setFill(); bounds.fill()
            if backdrop == "mixed" {
                NSColor.white.setFill(); NSRect(x: bounds.midX, y: 0, width: bounds.width/2, height: bounds.height).fill()
            } else if backdrop == "narrow" {
                NSColor.white.setFill(); NSRect(x: bounds.midX, y: 0, width: 8, height: bounds.height).fill()
            } else if backdrop == "checker" {
                NSColor.white.setFill()
                for x in stride(from: 0.0, to: bounds.width, by: 8) {
                    for y in stride(from: 0.0, to: bounds.height, by: 8) where (Int(x/8)+Int(y/8)).isMultiple(of: 2) {
                        NSRect(x: x, y: y, width: 8, height: 8).fill()
                    }
                }
            } else {
                for x in stride(from: 0.0, to: bounds.width, by: 90) {
                    NSColor(srgbRed: 0.08, green: 0.16, blue: 0.24, alpha: 1).setFill()
                    NSRect(x: x, y: 0, width: 30, height: bounds.height).fill()
                }
            }
            return
        }
        NSColor(srgbRed: 0.15, green: 0.23, blue: 0.4, alpha: 1).setFill()
        bounds.fill()
        let colors: [NSColor] = [.systemBlue, .systemPurple, .systemOrange, .systemTeal]
        for x in stride(from: -80.0, through: bounds.width + 80, by: 80) {
            let index = (Int((x + 80) / 80)) % colors.count
            colors[index].setFill()
            NSRect(x: x + phase, y: 0, width: 40, height: bounds.height).fill()
        }
        for y in stride(from: 12.0, through: bounds.height - 12, by: 40) {
            ("背景测试 Background 0123456789" as NSString).draw(at: NSPoint(x: 20 + phase, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: 18, weight: .medium), .foregroundColor: NSColor.white])
        }
    }
}

final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    var timer: Timer?
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.main else { NSApp.terminate(nil); return }
        let args = CommandLine.arguments
        let large = args.contains("--large")
        let fullscreen = args.contains("--fullscreen-probe")
        let size = fullscreen ? NSSize(width: screen.visibleFrame.width-40, height: screen.visibleFrame.height-80)
            : (large ? screen.visibleFrame.size : NSSize(width: 600, height: 200))
        var rect = NSRect(x: screen.visibleFrame.midX - size.width/2, y: screen.visibleFrame.midY - size.height/2, width: size.width, height: size.height)
        if args.contains("--test-corner"), !large {
            let glass = NSSize(width: 800 / screen.backingScaleFactor, height: 100 / screen.backingScaleFactor)
            rect.origin = NSPoint(x: screen.visibleFrame.minX + 100 + glass.width/2 - size.width/2,
                                  y: screen.visibleFrame.maxY - 160 - glass.height/2 - size.height/2)
        }
        let window = NSWindow(contentRect: rect, styleMask: fullscreen ? [.titled, .closable, .resizable] : .borderless, backing: .buffered, defer: false)
        window.title = "GlassFrame Background Test"
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        if args.contains("--protected-window") { window.sharingType = .none }
        window.level = fullscreen ? .normal : NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        let view = Pattern(frame: NSRect(origin: .zero, size: size))
        if let i = args.firstIndex(of: "--background"), i + 1 < args.count { view.backdrop = args[i+1] }
        window.contentView = view
        window.orderFrontRegardless()
        self.window = window
        if fullscreen {
            window.collectionBehavior = [.fullScreenPrimary]
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            func record(_ stage: String) {
                guard let i = args.firstIndex(of: "--output"), i+1 < args.count else { return }
                let data: [String: Any] = ["stage": stage, "fullscreen": window.styleMask.contains(.fullScreen),
                    "window_number": window.windowNumber, "frontmost_bundle": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"]
                do {
                    try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]).write(
                        to: URL(fileURLWithPath: args[i+1]).appendingPathComponent("fixture-\(stage).json"), options: .atomic)
                } catch { fputs("Fixture evidence failed: \(error)\n", stderr); NSApp.terminate(nil) }
            }
            Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { _ in record("normal") }
            Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { _ in window.toggleFullScreen(nil) }
            Timer.scheduledTimer(withTimeInterval: 7, repeats: false) { _ in record("fullscreen") }
            Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { _ in window.toggleFullScreen(nil) }
            Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { _ in record("restored") }
        }
        if args.contains("--upgrade-background") {
            Timer.scheduledTimer(withTimeInterval: 33, repeats: false) { _ in view.backdrop = "white"; view.needsDisplay = true }
            Timer.scheduledTimer(withTimeInterval: 38, repeats: false) { _ in view.backdrop = "dark"; view.needsDisplay = true }
        }
        let start = ProcessInfo.processInfo.systemUptime
        if args.contains("--animate") {
            timer = Timer.scheduledTimer(withTimeInterval: 1/30.0, repeats: true) { [weak view] _ in
                view?.phase = ((ProcessInfo.processInfo.systemUptime-start)*60).truncatingRemainder(dividingBy: 80)
                view?.needsDisplay = true
            }
        }
        if let i=args.firstIndex(of: "--duration"), i+1<args.count, let duration=Double(args[i+1]), duration>0 {
            Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { _ in NSApp.terminate(nil) }
        }
        print("READY fixture=\(window.windowNumber) animated=\(args.contains("--animate"))")
        if args.contains("--protected-window") { print("WINDOW_SHARING_TYPE \(window.sharingType.rawValue)") }
        fflush(stdout)
    }
}
let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
withExtendedLifetime(delegate) { app.run() }
