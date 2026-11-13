import SwiftUI

/// The aggregate design language: the single value type every component reads
/// its colors, spacing, type, radii, elevation and motion from.
///
/// Injected through the SwiftUI environment (`\.designTokens`) so an app shell
/// can theme an entire subtree at once. A `\.albumTheme` may override the accent
/// and supply an art-derived background on top of these base tokens.
public struct DesignTokens: Sendable, Equatable {
    public var colors: ColorPalette
    public var spacing: SpacingScale
    public var typography: TypographyScale
    public var radii: CornerRadii
    public var elevation: ElevationScale
    public var motion: MotionTokens

    public init(
        colors: ColorPalette,
        spacing: SpacingScale,
        typography: TypographyScale,
        radii: CornerRadii,
        elevation: ElevationScale,
        motion: MotionTokens
    ) {
        self.colors = colors
        self.spacing = spacing
        self.typography = typography
        self.radii = radii
        self.elevation = elevation
        self.motion = motion
    }
}

public extension DesignTokens {
    static let standard = DesignTokens(
        colors: .standard,
        spacing: .standard,
        typography: .standard,
        radii: .standard,
        elevation: .standard,
        motion: .standard
    )
}

public extension EnvironmentValues {
    @Entry var designTokens: DesignTokens = .standard
}

public extension View {
    /// Themes a subtree with the given design tokens.
    func designTokens(_ tokens: DesignTokens) -> some View {
        environment(\.designTokens, tokens)
    }
}
