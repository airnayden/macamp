// HeadroomSuggestion — the analytic answer to "is this signal path about to clip,
// and by how much?".
//
// ``GainComposer`` records the CONSTANT gain each contributor applies, but a
// parametric filter bank's boost is a function of frequency: a bank whose preamp
// is 0 dB can still add +6 dB at its centre frequency. The compound peak is
// therefore the gain ledger plus the bank's own maximum response, evaluated the
// way AutoEq's `max_gain` does it — sweep the band and take the largest value the
// curve reaches.
//
// When that total is positive the listener is over unity and the path can clip.
// MacAMP answers with a SUGGESTION, never an automatic correction: the trim is
// applied only by ``GainComposer/applyHeadroomSuggestion(_:)``, and only from an
// explicit user action. Silently attenuating someone's carefully chosen EQ would
// be a worse failure than the clipping it prevents.
//
// This file imports only Foundation; it MUST NOT import AppKit or UIKit
// (PlayerCore portability invariant).
import Foundation

/// The compound peak gain a signal path can produce, broken down by contributor.
///
/// Every field is in dB and UNCLAMPED — deliberately, because
/// ``GainComposer/composedGainDB`` clamps to the engine's −96…+24 port range and
/// a clamp would hide exactly the over-boost this analysis exists to find.
public struct HeadroomAnalysis: Sendable, Equatable {
    /// Trims smaller than this are not worth offering: below the 0.1 dB
    /// resolution the figure is displayed at, a "suggestion" is rounding noise.
    public static let minimumSuggestibleDB: Double = 0.1

    /// The ReplayGain summand, already mode-selected and anti-clip limited.
    public let replayGainDB: Double

    /// The ten-band graphic EQ's pre-amp.
    public let graphicPreampDB: Double

    /// The parametric bank's pre-amp — its `Preamp:` line, not its filters.
    public let parametricPreampDB: Double

    /// The parametric bank's own largest response across the audible band,
    /// EXCLUDING ``parametricPreampDB`` so the two never double-count.
    public let parametricPeakDB: Double

    /// The trim already in force, which is what makes an accepted suggestion
    /// idempotent: once applied, the compound peak lands at 0 and the next
    /// analysis offers nothing.
    public let headroomTrimDB: Double

    public init(
        replayGainDB: Double,
        graphicPreampDB: Double,
        parametricPreampDB: Double,
        parametricPeakDB: Double,
        headroomTrimDB: Double
    ) {
        self.replayGainDB = replayGainDB
        self.graphicPreampDB = graphicPreampDB
        self.parametricPreampDB = parametricPreampDB
        self.parametricPeakDB = parametricPeakDB
        self.headroomTrimDB = headroomTrimDB
    }

    /// The largest gain this path can apply at any frequency.
    public var compoundPeakDB: Double {
        replayGainDB + graphicPreampDB + parametricPreampDB + parametricPeakDB + headroomTrimDB
    }

    /// How much to trim to bring ``compoundPeakDB`` back to unity — negative, and
    /// `nil` when nothing is boosting enough to be worth offering.
    public var suggestedTrimDB: Double? {
        compoundPeakDB >= Self.minimumSuggestibleDB ? -compoundPeakDB : nil
    }

    /// The ABSOLUTE trim accepting this suggestion writes to ``GainComposer``.
    ///
    /// ``GainComposer/setHeadroomTrim(_:)`` replaces its summand rather than
    /// accumulating, and ``compoundPeakDB`` already counts the trim in force, so
    /// the new value is the old trim plus the suggested delta.
    public var resolvedTrimDB: Double? {
        suggestedTrimDB.map { headroomTrimDB + $0 }
    }
}

/// The frequency grid the compound-peak analysis sweeps.
///
/// Geometric with a 1.01 ratio over the audible band — AutoEq's own
/// `generate_frequencies` shape, which is what makes MacAMP's figure comparable
/// to the preamp an AutoEq profile ships with.
public enum HeadroomSweep {
    public static let lowerFrequency: Double = 20
    public static let upperFrequency: Double = 20000
    public static let stepRatio: Double = 1.01

    /// The grid over `sampleRate`'s usable band, with `extras` folded in.
    ///
    /// A geometric grid alone can straddle a narrow filter's centre and read
    /// several tenths of a dB low on it, so each filter's own frequency is added
    /// verbatim: a peaking filter reaches its stated gain EXACTLY at its centre,
    /// which turns the one point that matters most into an exact sample rather
    /// than an interpolation.
    ///
    /// The band is capped at Nyquist because the magnitude evaluation wraps above
    /// it, and `extras` are clamped into the band for the same reason.
    public static func frequencies(sampleRate: Double, including extras: [Double] = []) -> [Double] {
        let upper = min(upperFrequency, sampleRate / 2)
        guard upper > lowerFrequency else { return [lowerFrequency] }
        var grid: [Double] = []
        var frequency = lowerFrequency
        while frequency < upper {
            grid.append(frequency)
            frequency *= stepRatio
        }
        grid.append(upper)
        grid.append(contentsOf: extras.map { min(max($0, lowerFrequency), upper) })
        return grid
    }
}

public extension ParametricEQConfiguration {
    /// The bank's largest combined filter response across the audible band, in dB
    /// — AutoEq's `max_gain`, and the frequency-dependent half of
    /// ``HeadroomAnalysis/compoundPeakDB``.
    ///
    /// Excludes ``preampDB``, which is a constant the gain composer already owns.
    ///
    /// Costs a biquad design and a magnitude evaluation per filter per grid point
    /// — a couple of milliseconds for a full bank. Evaluate it when the
    /// configuration or the gain ledger changes, not on a display cadence.
    func maximumFilterResponseDB(sampleRate: Double) -> Double {
        HeadroomSweep
            .frequencies(sampleRate: sampleRate, including: filters.map(\.frequency))
            .reduce(0) { peak, frequency in
                max(peak, filterResponseDB(atFrequency: frequency, sampleRate: sampleRate))
            }
    }
}

// MARK: - Gain ledger bridge

@MainActor
public extension GainComposer {
    /// The compound peak this ledger plus `configuration` can produce.
    ///
    /// Pass the configuration currently INSTALLED on the engine: the pre-amp
    /// summand is read from the ledger, so a configuration that was never
    /// installed would pair its filters with somebody else's pre-amp.
    func headroomAnalysis(
        parametricConfiguration configuration: ParametricEQConfiguration?,
        sampleRate: Double
    ) -> HeadroomAnalysis {
        HeadroomAnalysis(
            replayGainDB: Double(replayGainDB),
            graphicPreampDB: Double(graphicPreampDB),
            parametricPreampDB: Double(parametricPreampDB),
            parametricPeakDB: configuration?.maximumFilterResponseDB(sampleRate: sampleRate) ?? 0,
            headroomTrimDB: Double(headroomTrimDB)
        )
    }

    /// Applies `analysis`'s suggested trim, returning `false` when it had none.
    ///
    /// The ONLY write the head-room suggestion performs, and it must be reached
    /// from an explicit user action — nothing in the engine, the coordinator, or
    /// the meter may call it on the listener's behalf.
    @discardableResult
    func applyHeadroomSuggestion(_ analysis: HeadroomAnalysis) -> Bool {
        guard let trim = analysis.resolvedTrimDB else { return false }
        setHeadroomTrim(Float(trim))
        return true
    }
}
