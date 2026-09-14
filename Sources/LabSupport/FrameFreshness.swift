import Foundation

/// Leave 50 ms of the accepted 250 ms end-to-end budget for presentation.
/// Static pixels can remain on screen; a geometry commit needs a recent sample.
public enum FrameFreshness {
    public static let maximumGeometryAge: Double = 0.2
    public static func allowsGeometry(capturedAt: Double, now: Double) -> Bool {
        capturedAt.isFinite && now.isFinite && capturedAt <= now && now-capturedAt <= maximumGeometryAge
    }
}
