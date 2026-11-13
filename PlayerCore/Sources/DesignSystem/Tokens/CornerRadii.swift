import CoreGraphics

/// Corner-radius tokens. Paired with `.continuous` rounded rectangles in
/// components for the soft, optical curvature the design language calls for.
public struct CornerRadii: Sendable, Equatable {
    public var small: CGFloat
    public var medium: CGFloat
    public var large: CGFloat
    public var xLarge: CGFloat
    public var pill: CGFloat

    public init(small: CGFloat, medium: CGFloat, large: CGFloat, xLarge: CGFloat, pill: CGFloat) {
        self.small = small
        self.medium = medium
        self.large = large
        self.xLarge = xLarge
        self.pill = pill
    }
}

public extension CornerRadii {
    static let standard = CornerRadii(
        small: 8,
        medium: 12,
        large: 16,
        xLarge: 24,
        pill: 999
    )
}
