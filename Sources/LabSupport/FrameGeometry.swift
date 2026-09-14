import Foundation
import CoreGraphics

public struct FrameGeometryResult: Sendable {
    public let frame: CGRect
    public let actualPixels: CGSize
    public let glassFrame: CGRect
    public let sizeLimited: Bool
    public let usedDefaultInput: Bool
}

public enum FrameGeometry {
    public static func interpolate(from start: CGRect, to target: CGRect, progress: Double) -> CGRect {
        let t = progress.isFinite ? min(1, max(0, progress)) : 0
        let eased = t * t * (3 - 2 * t)
        return CGRect(x: start.minX + (target.minX-start.minX)*eased,
                      y: start.minY + (target.minY-start.minY)*eased,
                      width: start.width + (target.width-start.width)*eased,
                      height: start.height + (target.height-start.height)*eased)
    }
    public static func resolve(requested: FramePixelSize, backingScale: Double,
                               visibleFrame: CGRect, currentFrame: CGRect?, shadowInset: Double = 0, alignToWindowPoints: Bool = false) throws -> FrameGeometryResult {
        guard visibleFrame.width > 48, visibleFrame.height > 0,
              visibleFrame.origin.x.isFinite, visibleFrame.origin.y.isFinite,
              visibleFrame.width.isFinite, visibleFrame.height.isFinite else {
            throw OptionError.invalid("No usable display area for frame")
        }
        guard shadowInset.isFinite, shadowInset >= 0,
              visibleFrame.width - 48 > shadowInset * 2,
              visibleFrame.height * 0.8 > shadowInset * 2 else {
            throw OptionError.invalid("No usable glass area after shadow insets")
        }
        let invalid = !requested.width.isFinite || !requested.height.isFinite || requested.width <= 0 || requested.height <= 0
        let input = invalid ? FramePixelSize.minimum : requested
        let desired = try FramePixelSize(width: max(800, input.width), height: max(100, input.height)).points(backingScale: backingScale)
        let maxWidth = visibleFrame.width - 48
        let maxHeight = visibleFrame.height * 0.8
        let rawWidth = min(desired.width + shadowInset * 2, maxWidth)
        let rawHeight = min(desired.height + shadowInset * 2, maxHeight)
        // AppKit normalizes borderless window origins down and sizes up to whole points.
        // Resolve that geometry before rendering so exact presentation checks use the same frame.
        let width = alignToWindowPoints ? min(ceil(rawWidth), floor(maxWidth)) : rawWidth
        let height = alignToWindowPoints ? min(ceil(rawHeight), floor(maxHeight)) : rawHeight
        let glassWidth = width - shadowInset * 2
        let glassHeight = height - shadowInset * 2
        let center = currentFrame.map { CGPoint(x: $0.midX, y: $0.midY) }
            ?? CGPoint(x: visibleFrame.midX, y: visibleFrame.midY)
        let x = min(max(center.x - width / 2, visibleFrame.minX + 24), visibleFrame.maxX - 24 - width)
        let y = min(max(center.y - height / 2, visibleFrame.minY), visibleFrame.maxY - height)
        let alignedX = alignToWindowPoints ? min(max(floor(x), ceil(visibleFrame.minX + 24)), floor(visibleFrame.maxX - 24 - width)) : x
        let alignedY = alignToWindowPoints ? min(max(floor(y), ceil(visibleFrame.minY)), floor(visibleFrame.maxY - height)) : y
        let panel = CGRect(x: alignedX, y: alignedY, width: width, height: height)
        return FrameGeometryResult(frame: panel,
                                   actualPixels: CGSize(width: glassWidth * backingScale, height: glassHeight * backingScale),
                                   glassFrame: panel.insetBy(dx: shadowInset, dy: shadowInset),
                                   sizeLimited: glassWidth < desired.width || glassHeight < desired.height,
                                   usedDefaultInput: invalid)
    }
}
