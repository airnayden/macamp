// SpectrumBallistics — the shared attack/release envelope every on-screen
// spectrum consumer applies to the raw analysis it pulls.
//
// The DSP layer deliberately ships NO temporal smoothing (PlayerCore README §5),
// so a consumer that renders `latestSpectrum()` verbatim flickers: a transient
// occupies one frame and is gone. Each consumer owns its OWN instance and steps
// it on its own cadence — the Metal path at 60 fps, the compact player-bar
// spectrum at 30 fps — so nothing is shared between them but this type.
import Foundation

/// Per-band instant-attack / exponential-release envelope.
///
/// `step(new:elapsed:)` is a pure function of (previous levels, new levels,
/// elapsed) — no clock is read internally, so the caller's cadence is fully
/// injectable and every result is reproducible.
public struct SpectrumBallistics: Sendable {
    /// Fraction of a band's level retained across one 60 fps frame.
    public static let releaseFactorPerTick: Float = 0.85

    /// The cadence ``releaseFactorPerTick`` is defined against.
    public static let referenceInterval: Double = 1.0 / 60.0

    /// Decay is capped at one second of release so a stalled consumer resumes at
    /// the floor instead of computing an unbounded power.
    private static let maxDecayInterval: Double = 1.0

    private var levels: [Float] = []

    public init() {}

    /// The level retained per band after `elapsed` seconds, scaled off wall clock
    /// so a 30 fps consumer decays at the same rate per SECOND as a 60 fps one.
    public static func releaseFactor(elapsed: Double) -> Float {
        guard elapsed.isFinite, elapsed > 0 else { return 1 }
        let ticks = min(elapsed, maxDecayInterval) / referenceInterval
        return Float(pow(Double(releaseFactorPerTick), ticks))
    }

    /// Envelopes one pulled frame: a band rises to `new` immediately and falls
    /// toward it along the release curve.
    ///
    /// An empty `new` (an inactive source) clears the envelope, and a band-count
    /// change adopts the new frame outright rather than blending mismatched bands.
    public mutating func step(new: [Float], elapsed: Double) -> [Float] {
        guard !new.isEmpty else {
            levels = []
            return []
        }
        guard levels.count == new.count else {
            levels = new
            return levels
        }
        let factor = Self.releaseFactor(elapsed: elapsed)
        for index in levels.indices {
            levels[index] = max(new[index], levels[index] * factor)
        }
        return levels
    }

    /// Drops all retained levels so the next ``step(new:elapsed:)`` starts clean.
    public mutating func reset() {
        levels = []
    }
}
