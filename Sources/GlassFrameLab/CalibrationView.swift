import AppKit

/// A fixed test pattern for screenshot reproducibility. This is not the product UI.
final class CalibrationView: NSView {
    var onDraw: (() -> Void)?
    var phase: CGFloat = 0
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        onDraw?()
        NSColor(calibratedRed: 0.07, green: 0.09, blue: 0.14, alpha: 1).setFill()
        bounds.fill()
        let colors: [NSColor] = [.systemPink, .systemPurple, .systemBlue, .systemTeal]
        for (index, color) in colors.enumerated() {
            color.setFill()
            NSRect(x: CGFloat(index) * bounds.width / 4, y: 0,
                   width: bounds.width / 4, height: 12).fill()
        }
        let title = "GlassFrame Lab · WP-00"
        title.draw(at: NSPoint(x: 28, y: 164), withAttributes: [
            .font: NSFont.systemFont(ofSize: 24, weight: .semibold), .foregroundColor: NSColor.white
        ])
        "Window / screenshot / metrics calibration".draw(at: NSPoint(x: 28, y: 128), withAttributes: [
            .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.lightGray
        ])
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: 28 + phase * (bounds.width - 76), y: 48, width: 20, height: 20)).fill()
    }
}
