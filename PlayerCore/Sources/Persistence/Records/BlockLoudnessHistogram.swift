import Foundation

/// Why a ``BlockLoudnessHistogram`` blob was refused.
public enum BlockLoudnessHistogramError: Error, Sendable, Equatable {
    /// The blob was not exactly ``BlockLoudnessHistogram/byteCount`` bytes, or the
    /// count array was not ``BlockLoudnessHistogram/binCount`` long. Rejected rather
    /// than padded or truncated: a short blob would silently misalign every bin, and
    /// a misaligned histogram pools into a wrong album gain rather than an obvious
    /// failure.
    case invalidHistogramSize(expected: Int, actual: Int)
}

/// The fixed-size histogram of absolute-gate-passing block loudnesses stored in
/// `trackLoudness.blockPowersHistogram`.
///
/// ``binCount`` `UInt32` counts in 0.1 dB bins spanning −70…+5 LKFS — about 3 KB per
/// row, **bounded regardless of track length**, where retaining the raw block set
/// would grow with duration (a 400 ms block every 100 ms is 10 values per second).
/// It is the representation libebur128's histogram mode uses, and it is deliberately
/// **not** a hash: both BS.1770-4 gates stay exactly recomputable to bin resolution,
/// and album pooling reduces to elementwise addition of two histograms.
///
/// ### Bin mapping
///
/// `bin = min(binCount - 1, Int((loudness + 70.0) * 10.0))`, so bin `b` covers
/// `[-70 + 0.1·b, -70 + 0.1·(b+1))` and its representative value — the one to use
/// when converting a bin back to power — is its centre,
/// ``binCentreLKFS(_:)`` = `-69.95 + 0.1·b`.
///
/// Three rules make that mapping total, and each exists because of a real input:
///
/// 1. **Non-finite loudness is DROPPED, never binned.** Digital silence has power
///    exactly `0`, so its block loudness is `-infinity`, and `Int()` on a non-finite
///    `Double` **traps at runtime**. Every lead-in, gap and fade-out contains such
///    blocks, so this is the common case rather than a defensive edge.
/// 2. **Blocks at or below −70 LKFS are DROPPED, never clamped into bin 0.** Clamping
///    would invent gate-passing programme out of silence and drag the pooled album
///    figure down. `LoudnessMeasurement.gatedBlockLoudness` has already applied the
///    absolute gate, so this only ever fires on a caller that hands over ungated
///    blocks — and then it fires correctly.
/// 3. **Blocks above the top bin SATURATE into the last bin.** Programme above
///    +5 LKFS is vanishingly rare and only reachable by a deliberately clipped
///    master; saturating keeps it counted as "very loud" instead of discarding it.
///
/// Only **absolute**-gate-passing blocks are histogrammed. The relative gate is never
/// pre-applied: it is derived from the pooled set, so trimming to it here would make
/// every album containing one quiet track re-derive Γr from an already-trimmed set
/// and read high.
public enum BlockLoudnessHistogram {
    /// Bins spanning −70…+5 LKFS at ``binWidthLKFS``.
    public static let binCount = 751
    /// Width of one bin, in LKFS.
    public static let binWidthLKFS = 0.1
    /// Bins per LKFS — the published formula's multiplier.
    ///
    /// Scaling by this is **not** interchangeable with dividing by ``binWidthLKFS``:
    /// measured over the 751 bin edges the two disagree on 54 of them, and over
    /// 700 000 sampled loudnesses on 95. Where they differ the multiply is the more
    /// accurate of the two (at −57.1 LKFS it yields bin 129, the divide 128), and it
    /// is the spelling the bin mapping was specified with. Do not "simplify" it.
    public static let binsPerLKFS = 10.0
    /// The histogram's lower edge. Blocks at or below it are dropped, not binned.
    public static let lowerEdgeLKFS = -70.0
    /// The exact byte length of a valid encoded histogram.
    public static let byteCount = binCount * MemoryLayout<UInt32>.size

    /// Bins `loudness`, or returns `nil` when the block must be dropped.
    ///
    /// Saturation is checked **before** the `Int` conversion, so a finite but absurd
    /// loudness (which would scale past `Int.max` and trap) lands in the last bin
    /// like any other over-range value.
    ///
    /// A loudness sitting exactly on a bin edge may land in the bin **below** — 76 of
    /// the 750 edges do, because neither `-70 + 0.1·b` nor its scaled round trip is
    /// representable in binary floating point. That is inherent to the specified
    /// formula and harmless: the misplacement is one 0.1 dB bin, which is the
    /// resolution both gates are recomputable to anyway, and a measured block loudness
    /// (`10·log10(…) − 0.691`) lands on an exact tenth only by coincidence. Nudging it
    /// with an epsilon would desync this histogram from every other implementation of
    /// the same mapping, so it is pinned by test rather than "fixed".
    public static func bin(forLoudness loudness: Double) -> Int? {
        guard loudness.isFinite, loudness > lowerEdgeLKFS else { return nil }
        let scaled = (loudness - lowerEdgeLKFS) * binsPerLKFS
        guard scaled < Double(binCount) else { return binCount - 1 }
        return Int(scaled)
    }

    /// The centre of `bin` in LKFS — the value to convert back to power with.
    public static func binCentreLKFS(_ bin: Int) -> Double {
        lowerEdgeLKFS + binWidthLKFS * (Double(bin) + 0.5)
    }

    /// Counts `blockLoudness` into ``binCount`` bins, dropping and saturating per the
    /// type's rules.
    public static func counts(forBlockLoudness blockLoudness: [Double]) -> [UInt32] {
        var counts = [UInt32](repeating: 0, count: binCount)
        for loudness in blockLoudness {
            guard let index = bin(forLoudness: loudness) else { continue }
            counts[index] = counts[index] == .max ? .max : counts[index] + 1
        }
        return counts
    }
}

// MARK: - Blob encoding

public extension BlockLoudnessHistogram {
    /// An all-zero blob of the correct length.
    static var emptyCounts: Data {
        Data(count: byteCount)
    }

    /// Packs ``binCount`` counts into a little-endian blob.
    static func encode(_ counts: [UInt32]) throws -> Data {
        guard counts.count == binCount else {
            throw BlockLoudnessHistogramError.invalidHistogramSize(
                expected: byteCount,
                actual: counts.count * MemoryLayout<UInt32>.size
            )
        }
        var data = Data(capacity: byteCount)
        for count in counts {
            withUnsafeBytes(of: count.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Bins `blockLoudness` and packs the result in one step.
    static func encode(blockLoudness: [Double]) throws -> Data {
        try encode(counts(forBlockLoudness: blockLoudness))
    }

    /// Unpacks a little-endian blob back into ``binCount`` counts.
    ///
    /// The bytes are reassembled by explicit shifting rather than a raw load, so the
    /// stored format stays little-endian regardless of the host's byte order.
    static func decode(_ data: Data) throws -> [UInt32] {
        try validate(data)
        let width = MemoryLayout<UInt32>.size
        return (0 ..< binCount).map { index in
            let start = data.startIndex + index * width
            var value: UInt32 = 0
            for offset in 0 ..< width {
                value |= UInt32(data[start + offset]) << (8 * offset)
            }
            return value
        }
    }

    /// Throws unless `data` is exactly ``byteCount`` bytes.
    static func validate(_ data: Data) throws {
        guard data.count == byteCount else {
            throw BlockLoudnessHistogramError.invalidHistogramSize(
                expected: byteCount,
                actual: data.count
            )
        }
    }
}

// MARK: - Album pooling

public extension BlockLoudnessHistogram {
    /// Pools album members by elementwise addition — the whole of album pooling at the
    /// histogram level.
    ///
    /// Saturates at `UInt32.max` instead of wrapping, on the ``PlaySegmentHeatRecord``
    /// precedent: a saturated bin still reads as "a great many blocks at this
    /// loudness", whereas a wrapped one would read as none.
    static func pooled(_ histograms: [[UInt32]]) throws -> [UInt32] {
        var total = [UInt32](repeating: 0, count: binCount)
        for histogram in histograms {
            guard histogram.count == binCount else {
                throw BlockLoudnessHistogramError.invalidHistogramSize(
                    expected: byteCount,
                    actual: histogram.count * MemoryLayout<UInt32>.size
                )
            }
            for index in 0 ..< binCount {
                let sum = UInt64(total[index]) + UInt64(histogram[index])
                total[index] = sum > UInt64(UInt32.max) ? .max : UInt32(sum)
            }
        }
        return total
    }

    /// Pools encoded blobs, decoding each on the way in.
    static func pooled(blobs: [Data]) throws -> [UInt32] {
        try pooled(blobs.map { try decode($0) })
    }
}
