import AppKit

/// Static native-glass outline, independent of the optional Metal decoration.
final class StaticGlassRim: NSView {
    var cornerRadius: CGFloat = 16 {
        didSet { if cornerRadius != oldValue { needsDisplay = true } }
    }
    private struct Geometry: Equatable {
        let size: NSSize
        let scale: CGFloat
        let radius: CGFloat
    }
    private var cachedGeometry: Geometry?
    override var isOpaque: Bool { false }
    override var wantsUpdateLayer: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { needsDisplay = true }
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsDisplay = true
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateLayer() {
        guard bounds.width > 0, bounds.height > 0 else {
            layer?.contents = nil
            cachedGeometry = nil
            return
        }
        let scale = window?.backingScaleFactor ?? 1
        let radius = min(cornerRadius, min(bounds.width, bounds.height) / 2)
        let targetWidth = max(1, Int((bounds.width * scale).rounded()))
        let targetHeight = max(1, Int((bounds.height * scale).rounded()))
        // Preserve corner pixels and stretch only constant straight-edge pixels.
        // This keeps resizing from allocating a new full-window image per frame.
        let cap = Int(ceil(max(radius, 0.85) * scale)) + 1
        let side = 2 * cap + 2
        let stretch = targetWidth >= side && targetHeight >= side
        let width = stretch ? side : targetWidth
        let height = stretch ? side : targetHeight
        let imageSize = NSSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale)
        let geometry = Geometry(size: imageSize, scale: scale, radius: radius)
        guard geometry != cachedGeometry else { return }
        // Give CGImage one owned buffer directly. Array -> Data -> CFData copies
        // otherwise create avoidable allocator pressure during animated resize.
        let byteCount = width * height * 4
        guard let data = CFDataCreateMutable(nil, byteCount) else { return }
        CFDataSetLength(data, byteCount)
        guard let pixels = CFDataGetMutableBytePtr(data) else { return }
        pixels.initialize(repeating: 0, count: byteCount)
        let cornerColumns = min(width / 2, Int(ceil(max(radius, 0.85) * scale + 1)))
        let edgeRows = Int(ceil(0.85 * scale + 0.5))
        for y in 0..<height {
            // Interior pixels are transparent. Only visit the top/bottom strips
            // and the corner/side strips, even while the frame is resizing.
            let ranges = y < edgeRows || y >= height - edgeRows
                ? [0..<width] : [0..<cornerColumns, (width - cornerColumns)..<width]
            for x in ranges.joined() {
                let px = (CGFloat(x) + 0.5) / scale
                let py = (CGFloat(y) + 0.5) / scale
                let qx = abs(px - imageSize.width / 2) - (imageSize.width / 2 - radius)
                let qy = abs(py - imageSize.height / 2) - (imageSize.height / 2 - radius)
                let distance = hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - radius
                // Difference of two coverage ramps, not separately joined arcs.
                // A one-pixel filter in distance space approximates pixel coverage;
                // the inner contour is offset by the 0.85 pt width.
                let outer = max(0, min(1, 0.5 - distance * scale))
                let inner = max(0, min(1, 0.5 - (distance + 0.85) * scale))
                let alpha = UInt8(((outer - inner) * 0.40 * 255).rounded())
                let offset = (y * width + x) * 4
                // White with premultiplied alpha; transparent pixels stay zero.
                for channel in 0..<4 { pixels[offset + channel] = alpha }
            }
        }
        guard let provider = CGDataProvider(data: data),
              let image = CGImage(width: width, height: height,
                  bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = scale
        layer?.contentsGravity = .resize
        layer?.contentsCenter = stretch
            ? CGRect(x: CGFloat(cap) / CGFloat(side), y: CGFloat(cap) / CGFloat(side),
                     width: 2 / CGFloat(side), height: 2 / CGFloat(side))
            : CGRect(x: 0, y: 0, width: 1, height: 1)
        layer?.contents = image
        CATransaction.commit()
        cachedGeometry = geometry
    }
}

/// Cached outside-only shadow. Its caster is erased before native glass sees it.
/// Kept with the rim so finite native fixtures compile the same decoration code.
final class StaticGlassOuterShadow: NSView {
    var cornerRadius: CGFloat = 16 { didSet { if cornerRadius != oldValue { needsDisplay = true } } }
    var extent: CGFloat = 6 { didSet { if extent != oldValue { needsDisplay = true } } }
    private struct Geometry: Equatable {
        let size: NSSize
        let scale: CGFloat
        let radius: CGFloat
        let extent: CGFloat
    }
    private var cachedGeometry: Geometry?
    override var isOpaque: Bool { false }
    override var wantsUpdateLayer: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { needsDisplay = true }
    }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); needsDisplay = true }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); needsDisplay = true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    override func updateLayer() {
        let glassSize = NSSize(width: bounds.width - 2 * extent, height: bounds.height - 2 * extent)
        guard extent > 0, glassSize.width > 0, glassSize.height > 0 else {
            layer?.contents = nil; cachedGeometry = nil; return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        // Contrast belongs to the base material, even with flow disabled/unavailable.
        layer?.opacity = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.14 : 0.20
        let scale = window?.backingScaleFactor ?? 1
        let radius = min(cornerRadius, min(glassSize.width, glassSize.height) / 2)
        let cap = Int(ceil((radius + extent) * scale)) + 1
        let side = 2 * cap + 2
        let targetWidth = max(1, Int((bounds.width * scale).rounded()))
        let targetHeight = max(1, Int((bounds.height * scale).rounded()))
        let stretch = targetWidth >= side && targetHeight >= side
        let width = stretch ? side : targetWidth
        let height = stretch ? side : targetHeight
        let size = NSSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale)
        let geometry = Geometry(size: size, scale: scale, radius: radius, extent: extent)
        guard geometry != cachedGeometry else { return }
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32) else { return }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.clear(NSRect(origin: .zero, size: size))
        let path = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size).insetBy(dx: extent, dy: extent),
                                xRadius: radius, yRadius: radius)
        let shadow = NSShadow()
        shadow.shadowOffset = .zero
        shadow.shadowBlurRadius = extent
        shadow.shadowColor = .black
        shadow.set()
        NSColor.black.setFill()
        path.fill()
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.setBlendMode(.clear)
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        guard let image = bitmap.cgImage else { return }
        layer?.contentsScale = scale
        layer?.contentsGravity = .resize
        layer?.contentsCenter = stretch
            ? CGRect(x: CGFloat(cap) / CGFloat(side), y: CGFloat(cap) / CGFloat(side), width: 2 / CGFloat(side), height: 2 / CGFloat(side))
            : CGRect(x: 0, y: 0, width: 1, height: 1)
        layer?.contents = image
        cachedGeometry = geometry
    }
}
