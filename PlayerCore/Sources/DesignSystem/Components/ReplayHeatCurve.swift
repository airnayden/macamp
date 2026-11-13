// ReplayHeatCurve — the "most replayed" curve painted behind a seek scrubber.
//
// Renders a per-track replay heatmap (100 relative buckets, already normalized to
// 0…1 by the caller) as ONE filled, smooth area spanning the scrubber's width, so
// the peaks line up with the positions in the song they describe. The smoothing is
// the classic quadratic-midpoint scheme: each bucket midpoint becomes the CONTROL
// point of a quadratic segment joining the midpoints of its two neighbouring spans,
// which is C1-continuous and — crucially — a pure function of the input.
//
// The geometry lives in `ReplayHeatGeometry`, a plain caseless enum, NOT on the
// view. `SwiftUI.View` is a `@MainActor` protocol, so every member of a conforming
// type (statics included) inherits main-actor isolation, and a nonisolated caller —
// a unit test — TRAPS at runtime rather than failing to compile. Keeping the maths
// off the view is what makes the shape directly assertable.
//
// Presentation rules, all by construction rather than by animation:
//   * Color is `\.designTokens`' accent — the SAME source `PlayerSlider` fills its
//     track with, so the curve can never drift to a different hue than the scrubber
//     it sits behind. No new theming mechanism.
//   * Opacity is a flat 0.35, or 0.5 when the shell reports increase-contrast
//     through `\.themePresentation`. There is NO blur and NO material, so
//     reduce-transparency is honored trivially.
//   * The reveal is a plain opacity toggle with NO animation attached, so
//     reduce-motion is honored trivially too.
//   * `allowsHitTesting(false)`: the curve is decoration layered around a slider
//     that owns a drag gesture, and must never steal a scrub.
//
// It draws NOTHING for empty, single-bucket, or all-zero input, so a track with no
// history contributes no stray path — and because callers layer it as a background
// or overlay it occupies no layout space either way.
import CoreGraphics
import SwiftUI

/// The pure geometry of a replay-heat curve: sampling, clamping, and smoothing.
public enum ReplayHeatGeometry {
    /// Relative buckets a track is divided into by the heatmap producer.
    ///
    /// Mirrors `PlaySegmentHeatRecord.bucketCount`. The curve itself works for any
    /// count ≥ 2; this is the value the app actually feeds it.
    public static let bucketCount = 100

    /// Whether `intensities` describes a curve worth drawing.
    ///
    /// Two buckets are the minimum a span can be drawn between, and an all-zero (or
    /// entirely non-finite) row is a track with no replay history — both render
    /// nothing rather than a degenerate baseline sliver across the scrubber.
    public static func hasContent(_ intensities: [Float]) -> Bool {
        intensities.count >= 2 && intensities.contains { $0.isFinite && $0 > 0 }
    }

    /// The closed, fillable path of the smoothed curve inside `rect`.
    ///
    /// Bucket *i* is sampled at the midpoint of its column, `(i + 0.5) / count` across
    /// `rect`, at height `intensity · rect.height` above `rect.maxY`. The area is
    /// closed along the bottom edge, and extended flat from the first/last bucket to
    /// the leading/trailing edges so the fill spans the whole scrubber with no
    /// wedge-shaped gaps at the ends.
    ///
    /// Returns an EMPTY path — never a degenerate one — when ``hasContent(_:)`` is
    /// `false` or `rect` has no area.
    public static func path(for intensities: [Float], in rect: CGRect) -> Path {
        var path = Path()
        guard hasContent(intensities), rect.width > 0, rect.height > 0 else { return path }
        let samples = points(for: intensities, in: rect)
        guard let first = samples.first, let last = samples.last, samples.count >= 2 else { return path }

        path.move(to: CGPoint(x: rect.minX, y: first.y))
        path.addLine(to: first)
        path.addLine(to: midpoint(samples[0], samples[1]))
        for index in 1 ..< (samples.count - 1) {
            path.addQuadCurve(to: midpoint(samples[index], samples[index + 1]), control: samples[index])
        }
        path.addLine(to: last)
        path.addLine(to: CGPoint(x: rect.maxX, y: last.y))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }

    /// One sample point per bucket, at its column midpoint. Intensities are clamped
    /// to 0…1 (non-finite reads as 0) so a corrupt row can never escape `rect`.
    public static func points(for intensities: [Float], in rect: CGRect) -> [CGPoint] {
        let step = rect.width / CGFloat(intensities.count)
        return intensities.enumerated().map { index, value in
            let clamped = CGFloat(min(max(value.isFinite ? value : 0, 0), 1))
            return CGPoint(
                x: rect.minX + (CGFloat(index) + 0.5) * step,
                y: rect.maxY - clamped * rect.height
            )
        }
    }

    private static func midpoint(_ lhs: CGPoint, _ rhs: CGPoint) -> CGPoint {
        CGPoint(x: (lhs.x + rhs.x) / 2, y: (lhs.y + rhs.y) / 2)
    }
}

/// The ``ReplayHeatGeometry`` area as a `Shape`, for callers that want to stroke,
/// clip, or mask it rather than take the styled view.
public struct ReplayHeatShape: Shape {
    public var intensities: [Float]

    public init(intensities: [Float]) {
        self.intensities = intensities
    }

    public func path(in rect: CGRect) -> Path {
        ReplayHeatGeometry.path(for: intensities, in: rect)
    }
}

/// A filled, smoothed "most replayed" curve for a track's relative listen counts.
///
/// `intensities` are normalized 0…1 values, one per relative bucket (the shipped
/// producer emits ``ReplayHeatGeometry/bucketCount``). Values outside 0…1, and
/// non-finite values, are clamped rather than rejected.
public struct ReplayHeatCurve: View {
    /// Fill opacity at standard contrast.
    public static let baseOpacity = 0.35

    /// Fill opacity when the shell reports increase-contrast.
    public static let increasedContrastOpacity = 0.5

    private let intensities: [Float]
    private let isRevealed: Bool

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme
    @Environment(\.themePresentation) private var presentation

    /// - Parameters:
    ///   - intensities: normalized 0…1 listen intensity per relative bucket.
    ///   - isRevealed: `false` fades the curve out entirely (opacity 0) and drops it
    ///     from the accessibility tree, without changing layout.
    public init(intensities: [Float], isRevealed: Bool = true) {
        self.intensities = intensities
        self.isRevealed = isRevealed
    }

    public var body: some View {
        ReplayHeatShape(intensities: intensities)
            .fill(tokens.colors.accent.resolve(scheme))
            .opacity(opacity)
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel(Text(DesignSystemStrings.replayHeatLabel))
            .accessibilityHidden(isSilent)
    }

    /// `true` when nothing is being shown — no data to draw, or not revealed.
    private var isSilent: Bool {
        !isRevealed || !ReplayHeatGeometry.hasContent(intensities)
    }

    private var opacity: Double {
        guard !isSilent else { return 0 }
        return presentation.increaseContrast ? Self.increasedContrastOpacity : Self.baseOpacity
    }
}
