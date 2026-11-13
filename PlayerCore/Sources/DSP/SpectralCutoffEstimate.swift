// SpectralCutoffEstimate — what a long-term averaged spectrum says about where a
// recording's content stops.
//
// This is a MEASUREMENT, not a judgement. Turning a cutoff into "this file looks
// like a transcode" is `FakeLosslessRule`'s job, deliberately kept separate so the
// measurement can be inspected, logged and tested without inheriting the
// heuristic's opinion.
import Foundation

/// Why a spectral cutoff could not be estimated.
///
/// Every case means "no answer", never "nothing wrong" — a caller must not read an
/// indeterminate result as a clean bill of health.
public enum SpectralIndeterminateReason: String, Sendable, Equatable, CaseIterable {
    /// Too few complete analysis windows to average (a very short or empty stream).
    case insufficientAudio

    /// The material sits at or below the analysis gate, so every bin is noise about
    /// noise. Digital silence lands here rather than dividing by a zero reference.
    case silentOrTooQuiet

    /// Nyquist is too low for the reference band the estimator anchors against.
    case unusableSampleRate
}

/// A spectral cutoff measured from the long-term average magnitude spectrum.
public struct SpectralCutoffEstimate: Sendable, Equatable {
    /// Centre frequency of the highest bin whose long-term average cleared the
    /// threshold.
    public let cutoffHz: Double

    public let nyquistHz: Double

    /// Level of the dead-band probe (the topmost bins), relative to the reference
    /// band. Deeply negative means the top of the spectrum is empty.
    public let noiseFloorDB: Double

    /// The level a bin had to clear to count as content, relative to the reference
    /// band.
    public let thresholdDB: Double

    public let windowCount: Int

    public init(
        cutoffHz: Double,
        nyquistHz: Double,
        noiseFloorDB: Double,
        thresholdDB: Double,
        windowCount: Int
    ) {
        self.cutoffHz = cutoffHz
        self.nyquistHz = nyquistHz
        self.noiseFloorDB = noiseFloorDB
        self.thresholdDB = thresholdDB
        self.windowCount = windowCount
    }

    /// `cutoffHz` as a fraction of Nyquist — `1.0` for content reaching the top of
    /// the sample rate, lower for a band-limited stream.
    public var cutoffRatio: Double {
        guard nyquistHz > 0 else { return 0 }
        return cutoffHz / nyquistHz
    }
}

/// The result of a cutoff estimation pass.
public enum SpectralCutoffOutcome: Sendable, Equatable {
    case estimated(SpectralCutoffEstimate)
    case indeterminate(SpectralIndeterminateReason)

    public var estimate: SpectralCutoffEstimate? {
        guard case let .estimated(estimate) = self else { return nil }
        return estimate
    }
}
