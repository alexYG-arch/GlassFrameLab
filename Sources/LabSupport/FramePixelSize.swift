import Foundation

public struct FramePixelSize: Sendable {
    public let width: Double
    public let height: Double
    public static let minimum = FramePixelSize(width: 800, height: 100)

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public func points(backingScale: Double) throws -> CGSize {
        guard backingScale.isFinite, backingScale >= 1,
              width.isFinite, width > 0, height.isFinite, height > 0 else {
            throw OptionError.invalid("Pixel dimensions must be positive and display backingScale must be at least 1")
        }
        return CGSize(width: width / backingScale, height: height / backingScale)
    }
}
