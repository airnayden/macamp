// StatsQuantization — the two numeric rules every statistics total obeys.
//
// Statistics are reduced from rows the database is free to visit in any order, and
// the digest must be a pure function of the SET of rows. Floating-point addition is
// not associative, so summing `Double` seconds directly would let two runs over the
// same rows disagree in the last bits — and a byte-equal JSON snapshot would fail
// for no reason a reader could see.
//
// So:
//
//  * ``StatsSeconds`` quantizes seconds to whole microseconds BEFORE summing.
//    Integer addition is associative, which makes every total order-independent.
//    This is the rule the rollup compactor already applies in SQL
//    (`SUM(CAST(ROUND(secondsListened * 1000000.0) AS INTEGER))`); it lives here so
//    the compactor and the digest cannot drift apart.
//  * ``StatsRounding`` is the single fixed-precision rounding used for every
//    fraction and rate the digest publishes. `.toNearestOrEven` (banker's rounding)
//    is chosen over `.toNearestOrAwayFromZero` because it has no bias, and because
//    it is the tie rule IEEE 754 itself uses — so the same value rounds the same way
//    on every machine.
import Foundation

/// Seconds ⇄ whole microseconds, so accumulation is exact and order-independent.
public enum StatsSeconds {
    /// The quantization scale: one second is a million storable units.
    public static let microsecondsPerSecond: Double = 1_000_000

    /// Microseconds representable exactly as a `Double` (2^53), so the
    /// seconds ⇄ microseconds roundtrip is lossless. Clamping here is also what
    /// stops `Int64(_:)` trapping on a corrupt but finite input.
    public static let microsecondCeiling: Double = 9_007_199_254_740_992

    /// Quantizes seconds to whole microseconds.
    ///
    /// A non-finite input is corrupt rather than merely extreme, and collapses to
    /// zero: contributing nothing is the only reading that cannot poison a sum.
    public static func microseconds(fromSeconds seconds: Double) -> Int64 {
        guard seconds.isFinite else { return 0 }
        let scaled = (seconds * microsecondsPerSecond).rounded()
        return Int64(min(max(scaled, -microsecondCeiling), microsecondCeiling))
    }

    /// The inverse of ``microseconds(fromSeconds:)``, within the quantization step.
    public static func seconds(fromMicroseconds microseconds: Int64) -> Double {
        Double(microseconds) / microsecondsPerSecond
    }
}

/// The fixed-precision rounding every published fraction and rate goes through.
public enum StatsRounding {
    /// Decimal places kept for every fraction, rate and intensity in the digest.
    public static let fractionDigits = 4

    /// `10^fractionDigits`.
    public static let scale: Double = 10000

    /// Rounds to ``fractionDigits`` decimal places, half-to-even.
    ///
    /// A non-finite value collapses to zero rather than propagating: `JSONEncoder`
    /// refuses to encode a NaN, so letting one through would fail the whole digest
    /// at the last step instead of at the arithmetic that produced it.
    public static func rounded(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return (value * scale).rounded(.toNearestOrEven) / scale
    }

    /// ``rounded(_:)`` of `numerator / denominator`, with a zero denominator
    /// reading as `0` — "no plays" is not an error, it is an empty window.
    public static func ratio(_ numerator: Double, over denominator: Double) -> Double {
        guard denominator != 0 else { return 0 }
        return rounded(numerator / denominator)
    }
}
