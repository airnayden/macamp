import CoreGraphics

/// A drop-shadow token. Applied as a black shadow at `colorOpacity`; components
/// never inline shadow radii.
public struct ShadowToken: Sendable, Equatable {
    public var colorOpacity: Double
    public var radius: CGFloat
    public var offsetX: CGFloat
    public var offsetY: CGFloat

    public init(colorOpacity: Double, radius: CGFloat, offsetX: CGFloat = 0, offsetY: CGFloat) {
        self.colorOpacity = colorOpacity
        self.radius = radius
        self.offsetX = offsetX
        self.offsetY = offsetY
    }
}

/// Layered elevation steps from resting surface to floating overlay.
public struct ElevationScale: Sendable, Equatable {
    public var none: ShadowToken
    public var low: ShadowToken
    public var medium: ShadowToken
    public var high: ShadowToken

    public init(none: ShadowToken, low: ShadowToken, medium: ShadowToken, high: ShadowToken) {
        self.none = none
        self.low = low
        self.medium = medium
        self.high = high
    }
}

public extension ElevationScale {
    static let standard = ElevationScale(
        none: ShadowToken(colorOpacity: 0, radius: 0, offsetY: 0),
        low: ShadowToken(colorOpacity: 0.18, radius: 8, offsetY: 2),
        medium: ShadowToken(colorOpacity: 0.24, radius: 20, offsetY: 8),
        high: ShadowToken(colorOpacity: 0.34, radius: 40, offsetY: 16)
    )
}

/// Animation timing tokens (seconds). Honor reduce-motion by collapsing to
/// ``ThemePresentationOptions`` before use in views.
public struct MotionTokens: Sendable, Equatable {
    public var quick: Double
    public var standard: Double
    public var expressive: Double

    public init(quick: Double, standard: Double, expressive: Double) {
        self.quick = quick
        self.standard = standard
        self.expressive = expressive
    }
}

public extension MotionTokens {
    static let standard = MotionTokens(quick: 0.18, standard: 0.30, expressive: 0.5)
}
