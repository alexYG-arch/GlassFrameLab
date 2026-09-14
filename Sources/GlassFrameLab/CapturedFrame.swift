import CoreVideo
import CoreGraphics

struct CaptureMapping: Sendable, Equatable {
    let glassFrame: CGRect
    let displayFrame: CGRect
    let sourceRect: CGRect
    let scale: Double
    let width: Int
    let height: Int
    let sigma: Double

    var sourceFrameOnScreen: CGRect {
        CGRect(x: displayFrame.minX + sourceRect.minX, y: displayFrame.maxY - sourceRect.maxY,
               width: sourceRect.width, height: sourceRect.height)
    }
}

/// Capture produces immutable image contents; Metal only reads this retained buffer.
struct CapturedFrame: @unchecked Sendable {
    let buffer: CVPixelBuffer
    let sequence: Int
    let captureTime: Double
    let mapping: CaptureMapping
}
