import SwiftUI

/// The art-derived backdrop produced by ``ThemeExtractor``.
///
/// A `linearGradient` is the default expressive form; `solid` is the flat form
/// emitted when reduce-transparency is active, so the layer degrades gracefully
/// without the caller branching on accessibility state.
public enum ThemeBackground: Sendable, Equatable, Hashable {
    case solid(ColorValue)
    case linearGradient(stops: [ColorValue], angleDegrees: Double)

    /// SwiftUI `LinearGradient`/solid `Color` ready for a view's `.background`.
    @ViewBuilder
    public func shapeStyleView(for _: ColorScheme) -> some View {
        switch self {
        case let .solid(value):
            value.color
        case let .linearGradient(stops, angleDegrees):
            LinearGradient(
                colors: stops.map(\.color),
                startPoint: Self.unitPoint(forAngle: angleDegrees),
                endPoint: Self.unitPoint(forAngle: angleDegrees + 180)
            )
        }
    }

    private static func unitPoint(forAngle degrees: Double) -> UnitPoint {
        let radians = degrees * .pi / 180
        return UnitPoint(x: 0.5 + cos(radians) / 2, y: 0.5 + sin(radians) / 2)
    }
}
