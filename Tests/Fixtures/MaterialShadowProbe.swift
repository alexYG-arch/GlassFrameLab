import AppKit

let output = CommandLine.arguments[1]
for opacity: CGFloat in [0.04, 1.0] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 824, pixelsHigh: 124, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 824*4, bitsPerPixel: 32)!
    bitmap.size = NSSize(width: 412, height: 62)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let shadow = NSShadow()
    shadow.shadowOffset = .zero
    shadow.shadowBlurRadius = 6
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.14)
    shadow.set()
    NSColor.black.withAlphaComponent(opacity).setFill()
    NSBezierPath(roundedRect: NSRect(x: 6.5, y: 6.5, width: 399, height: 49), xRadius: 16, yRadius: 16).fill()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(output)/caster-\(opacity).png"))
}
