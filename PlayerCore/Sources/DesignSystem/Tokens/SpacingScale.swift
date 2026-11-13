import CoreGraphics

/// A 4-pt spacing grid. Components compose padding and gaps exclusively from
/// these steps — never from arbitrary magic numbers.
public struct SpacingScale: Sendable, Equatable {
    public var hairline: CGFloat
    public var xxSmall: CGFloat
    public var xSmall: CGFloat
    public var small: CGFloat
    public var medium: CGFloat
    public var large: CGFloat
    public var xLarge: CGFloat
    public var xxLarge: CGFloat
    public var xxxLarge: CGFloat

    public init(
        hairline: CGFloat,
        xxSmall: CGFloat,
        xSmall: CGFloat,
        small: CGFloat,
        medium: CGFloat,
        large: CGFloat,
        xLarge: CGFloat,
        xxLarge: CGFloat,
        xxxLarge: CGFloat
    ) {
        self.hairline = hairline
        self.xxSmall = xxSmall
        self.xSmall = xSmall
        self.small = small
        self.medium = medium
        self.large = large
        self.xLarge = xLarge
        self.xxLarge = xxLarge
        self.xxxLarge = xxxLarge
    }
}

public extension SpacingScale {
    static let standard = SpacingScale(
        hairline: 1,
        xxSmall: 4,
        xSmall: 8,
        small: 12,
        medium: 16,
        large: 24,
        xLarge: 32,
        xxLarge: 48,
        xxxLarge: 64
    )
}
