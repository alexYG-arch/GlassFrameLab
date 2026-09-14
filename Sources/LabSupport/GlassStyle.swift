import Foundation

/// Lengths are layout points, except sigma which is measured in sampling pixels.
public struct GlassStyle: Codable, Equatable, Sendable {
    public var sigma: Double = 12
    public var cornerRadius: Double = 16
    public var shadowExtent: Double = 6
    public var shadowOpacity: Double = 0.14
    public var shadowColor: [Double] = [0, 0, 0]
    public var innerStrength: Double = 0.16
    public var innerColor: [Double] = [1, 1, 1]
    public var innerWidth: Double = 3
    public var innerShade: Double = 0.055
    public var nonuniformity: Double = 0.85
    public var lightDirection: [Double] = [-0.6, -0.8]
    public var strokeWidth: Double = 0.55
    public var strokeColor: [Double] = [1, 1, 1]
    public var strokeOpacity: Double = 0.40
    public var saturation: Double = 1.08
    public var brightness: Double = 0
    public var tintColor: [Double] = [1, 1, 1]
    public var tintOpacity: Double = 0.008

    public init() {}

    private enum CodingKeys: String, CodingKey { case sigma, cornerRadius, shadowExtent, shadowOpacity, shadowColor, innerStrength, innerColor, innerWidth, innerShade, nonuniformity, lightDirection, strokeWidth, strokeColor, strokeOpacity, saturation, brightness, tintColor, tintOpacity }

    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sigma = try values.decodeIfPresent(Double.self, forKey: .sigma) ?? sigma
        cornerRadius = try values.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? cornerRadius
        shadowExtent = try values.decodeIfPresent(Double.self, forKey: .shadowExtent) ?? shadowExtent
        shadowOpacity = try values.decodeIfPresent(Double.self, forKey: .shadowOpacity) ?? shadowOpacity
        shadowColor = try values.decodeIfPresent([Double].self, forKey: .shadowColor) ?? shadowColor
        innerStrength = try values.decodeIfPresent(Double.self, forKey: .innerStrength) ?? innerStrength
        innerColor = try values.decodeIfPresent([Double].self, forKey: .innerColor) ?? innerColor
        innerWidth = try values.decodeIfPresent(Double.self, forKey: .innerWidth) ?? innerWidth
        innerShade = try values.decodeIfPresent(Double.self, forKey: .innerShade) ?? innerShade
        nonuniformity = try values.decodeIfPresent(Double.self, forKey: .nonuniformity) ?? nonuniformity
        lightDirection = try values.decodeIfPresent([Double].self, forKey: .lightDirection) ?? lightDirection
        strokeWidth = try values.decodeIfPresent(Double.self, forKey: .strokeWidth) ?? strokeWidth
        strokeColor = try values.decodeIfPresent([Double].self, forKey: .strokeColor) ?? strokeColor
        strokeOpacity = try values.decodeIfPresent(Double.self, forKey: .strokeOpacity) ?? strokeOpacity
        saturation = try values.decodeIfPresent(Double.self, forKey: .saturation) ?? saturation
        brightness = try values.decodeIfPresent(Double.self, forKey: .brightness) ?? brightness
        tintColor = try values.decodeIfPresent([Double].self, forKey: .tintColor) ?? tintColor
        tintOpacity = try values.decodeIfPresent(Double.self, forKey: .tintOpacity) ?? tintOpacity
    }

    public func validated() throws -> GlassStyle {
        let ranges: [(Double, ClosedRange<Double>)] = [
            (sigma, 0...40), (cornerRadius, 0...80), (shadowExtent, 1...16),
            (shadowOpacity, 0...0.4), (innerStrength, 0...0.5), (innerWidth, 0.1...12),
            (innerShade, 0...0.2), (nonuniformity, 0...1), (strokeWidth, 0...2),
            (strokeOpacity, 0...1), (saturation, 0...2), (brightness, -0.2...0.2), (tintOpacity, 0...0.4)
        ]
        guard ranges.allSatisfy({ $0.0.isFinite && $0.1.contains($0.0) }),
              shadowColor.count == 3, tintColor.count == 3, innerColor.count == 3, strokeColor.count == 3,
              (shadowColor + tintColor + innerColor + strokeColor).allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              lightDirection.count == 2, lightDirection.allSatisfy({ $0.isFinite && abs($0) <= 1 }),
              hypot(lightDirection[0], lightDirection[1]) > 0.001 else {
            throw OptionError.invalid("Invalid glass style values, color, or light direction")
        }
        return self
    }
}
