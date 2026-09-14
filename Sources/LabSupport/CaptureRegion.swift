import CoreGraphics

public struct CaptureRegion {
    public let sourceRect: CGRect
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(glassFrame: CGRect, displayFrame: CGRect, backingScale: Double,
                sampleScale: Double = 0.5, sigmaPixels: Double = 12) throws {
        guard backingScale.isFinite, backingScale >= 1,
              sampleScale.isFinite, sampleScale > 0, sampleScale <= 1,
              sigmaPixels.isFinite, sigmaPixels >= 0 else {
            throw OptionError.invalid("Invalid capture scale or sigma")
        }
        let marginPoints = 3 * sigmaPixels / (backingScale * sampleScale)
        let clipped = glassFrame.insetBy(dx: -marginPoints, dy: -marginPoints).intersection(displayFrame)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else {
            throw OptionError.invalid("Glass frame does not intersect the selected display")
        }
        sourceRect = CGRect(x: clipped.minX - displayFrame.minX,
                            y: displayFrame.maxY - clipped.maxY,
                            width: clipped.width, height: clipped.height)
        pixelWidth = Int(ceil(clipped.width * backingScale * sampleScale))
        pixelHeight = Int(ceil(clipped.height * backingScale * sampleScale))
    }
}
