import Foundation
import Persistence
import Testing

/// The bin mapping and blob encoding behind `trackLoudness.blockPowersHistogram`.
@Suite("BlockLoudnessHistogramTests")
struct BlockLoudnessHistogramTests {
    @Test("the histogram spans -70…+5.1 LKFS in 751 bins of 3004 bytes")
    func dimensions() {
        #expect(BlockLoudnessHistogram.binCount == 751)
        #expect(BlockLoudnessHistogram.binWidthLKFS == 0.1)
        #expect(BlockLoudnessHistogram.lowerEdgeLKFS == -70.0)
        #expect(BlockLoudnessHistogram.byteCount == 3004)
    }

    @Test("bin b's centre is -69.95 + 0.1·b")
    func binCentresFollowThePublishedFormula() {
        for bin in [0, 1, 375, 749, 750] {
            let expected = -69.95 + 0.1 * Double(bin)
            #expect(abs(BlockLoudnessHistogram.binCentreLKFS(bin) - expected) < 1e-9)
        }
    }

    @Test("in-range loudnesses land in the documented bins")
    func mapsInRangeLoudness() {
        #expect(BlockLoudnessHistogram.bin(forLoudness: -69.95) == 0)
        #expect(BlockLoudnessHistogram.bin(forLoudness: -69.8) == 2)
        #expect(BlockLoudnessHistogram.bin(forLoudness: -23.0) == 470)
        #expect(BlockLoudnessHistogram.bin(forLoudness: 4.95) == 749)
        #expect(BlockLoudnessHistogram.bin(forLoudness: 5.0) == 750)
    }

    /// The mapping must SCALE by ``BlockLoudnessHistogram/binsPerLKFS``, never divide
    /// by ``BlockLoudnessHistogram/binWidthLKFS``. The two look algebraically identical
    /// and disagree on 54 of the 751 bin edges; −57.1 LKFS is one of them, and the
    /// multiply is the more accurate as well as the specified form.
    @Test("the mapping multiplies by 10 rather than dividing by 0.1")
    func usesTheMultiplyForm() {
        #expect(BlockLoudnessHistogram.binsPerLKFS == 10.0)
        #expect(BlockLoudnessHistogram.bin(forLoudness: -57.1) == 129)
        #expect(Int((-57.1 - -70.0) / 0.1) == 128, "the divide form is what must NOT be used")
    }

    /// 76 of the 750 bin edges land one bin low because neither `-70 + 0.1·b` nor its
    /// scaled round trip is representable in binary floating point. Pinned rather than
    /// nudged with an epsilon: the misplacement is one 0.1 dB bin, and an epsilon would
    /// desync this histogram from every other implementation of the same mapping.
    @Test("a loudness exactly on a bin edge may land one bin low")
    func binEdgesMayLandOneBinLow() {
        #expect(BlockLoudnessHistogram.bin(forLoudness: -69.9) == 0)
        let lowEdges = (1 ..< BlockLoudnessHistogram.binCount).filter { bin in
            let edge = -70.0 + 0.1 * Double(bin)
            return BlockLoudnessHistogram.bin(forLoudness: edge) != bin
        }
        #expect(lowEdges.count == 76, "edge behaviour drifted: \(lowEdges.count) edges land low")
        #expect(lowEdges.allSatisfy { bin in
            let edge = -70.0 + 0.1 * Double(bin)
            return BlockLoudnessHistogram.bin(forLoudness: edge) == bin - 1
        }, "an edge must never miss by more than one bin")
    }

    /// Digital silence has power exactly `0`, so its block loudness is `-infinity`, and
    /// `Int()` on a non-finite `Double` traps. Every lead-in, gap and fade contains such
    /// blocks, so this is the common case — reaching the trap would crash a scan.
    @Test("non-finite loudness is dropped rather than binned")
    func dropsNonFiniteLoudness() {
        #expect(BlockLoudnessHistogram.bin(forLoudness: -.infinity) == nil)
        #expect(BlockLoudnessHistogram.bin(forLoudness: .infinity) == nil)
        #expect(BlockLoudnessHistogram.bin(forLoudness: .nan) == nil)
    }

    /// Clamping sub-gate blocks into bin 0 would invent gate-passing programme out of
    /// silence and drag every pooled album figure down.
    @Test("blocks at or below -70 LKFS are dropped, never clamped into bin 0")
    func dropsSubGateLoudness() {
        #expect(BlockLoudnessHistogram.bin(forLoudness: -70.0) == nil)
        #expect(BlockLoudnessHistogram.bin(forLoudness: -70.000001) == nil)
        #expect(BlockLoudnessHistogram.bin(forLoudness: -120.0) == nil)
        #expect(BlockLoudnessHistogram.bin(forLoudness: -69.999999) == 0)
    }

    /// The saturation guard runs before the `Int` conversion: a finite loudness that
    /// scales past `Int.max` would otherwise trap exactly like a non-finite one.
    @Test("loudness above the top bin saturates instead of trapping")
    func saturatesAboveTopBin() {
        #expect(BlockLoudnessHistogram.bin(forLoudness: 5.1) == 750)
        #expect(BlockLoudnessHistogram.bin(forLoudness: 40.0) == 750)
        #expect(BlockLoudnessHistogram.bin(forLoudness: 1e30) == 750)
        #expect(BlockLoudnessHistogram.bin(forLoudness: .greatestFiniteMagnitude) == 750)
    }

    @Test("counting applies every drop and saturate rule in one pass")
    func countsApplyAllRules() {
        let counts = BlockLoudnessHistogram.counts(forBlockLoudness: [
            -.infinity, .nan, -70.0, -90.0,
            -69.95, -69.95,
            5.0, 400.0,
        ])
        #expect(counts.count == BlockLoudnessHistogram.binCount)
        #expect(counts[0] == 2)
        #expect(counts[750] == 2)
        #expect(counts.reduce(0) { $0 + Int($1) } == 4, "four of the eight blocks are dropped")
    }

    @Test("counts round-trip through the blob unchanged")
    func encodingRoundTrips() throws {
        var counts = [UInt32](repeating: 0, count: BlockLoudnessHistogram.binCount)
        counts[0] = 1
        counts[1] = 256
        counts[375] = 70000
        counts[750] = .max
        let data = try BlockLoudnessHistogram.encode(counts)
        #expect(data.count == BlockLoudnessHistogram.byteCount)
        #expect(try BlockLoudnessHistogram.decode(data) == counts)
    }

    /// The blob is explicitly little-endian so an exported profile stays readable on a
    /// machine of the other byte order.
    @Test("the blob is little-endian regardless of host byte order")
    func encodingIsLittleEndian() throws {
        var counts = [UInt32](repeating: 0, count: BlockLoudnessHistogram.binCount)
        counts[0] = 1
        counts[1] = 256
        let data = try BlockLoudnessHistogram.encode(counts)
        #expect(Array(data.prefix(8)) == [0x01, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00])
    }

    @Test("a wrong-length blob or count array is refused, never padded")
    func refusesWrongLengths() {
        #expect(throws: BlockLoudnessHistogramError.self) {
            try BlockLoudnessHistogram.decode(Data(count: 3000))
        }
        #expect(throws: BlockLoudnessHistogramError.self) {
            try BlockLoudnessHistogram.encode([1, 2, 3])
        }
        #expect(throws: BlockLoudnessHistogramError.self) {
            try BlockLoudnessHistogram.pooled([[1, 2, 3]])
        }
    }

    @Test("encoding straight from block loudnesses bins on the way in")
    func encodesFromBlockLoudness() throws {
        let data = try BlockLoudnessHistogram.encode(blockLoudness: [-69.95, -69.95, -.infinity])
        #expect(try BlockLoudnessHistogram.decode(data)[0] == 2)
    }

    /// Album pooling IS elementwise addition — that is the whole reason the column is a
    /// histogram rather than a digest.
    @Test("pooling adds album members elementwise")
    func poolsElementwise() throws {
        let first = BlockLoudnessHistogram.counts(forBlockLoudness: [-23.0, -23.0, -14.0])
        let second = BlockLoudnessHistogram.counts(forBlockLoudness: [-23.0, -14.0])
        let pooled = try BlockLoudnessHistogram.pooled([first, second])
        #expect(pooled[470] == 3)
        #expect(pooled == BlockLoudnessHistogram.counts(
            forBlockLoudness: [-23.0, -23.0, -14.0, -23.0, -14.0]
        ))
    }

    /// A saturated bin still reads as "a great many blocks here"; a wrapped one would
    /// read as none.
    @Test("pooling saturates instead of wrapping")
    func poolingSaturates() throws {
        let full = [UInt32](repeating: .max, count: BlockLoudnessHistogram.binCount)
        let one = [UInt32](repeating: 1, count: BlockLoudnessHistogram.binCount)
        #expect(try BlockLoudnessHistogram.pooled([full, one]) == full)
    }

    @Test("pooling blobs decodes each on the way in")
    func poolsBlobs() throws {
        let blob = try BlockLoudnessHistogram.encode(blockLoudness: [-23.0])
        #expect(try BlockLoudnessHistogram.pooled(blobs: [blob, blob])[470] == 2)
    }

    @Test("the empty blob is the right length and all zero")
    func emptyCountsAreWellFormed() throws {
        #expect(BlockLoudnessHistogram.emptyCounts.count == BlockLoudnessHistogram.byteCount)
        #expect(try BlockLoudnessHistogram.decode(BlockLoudnessHistogram.emptyCounts).allSatisfy { $0 == 0 })
    }
}
