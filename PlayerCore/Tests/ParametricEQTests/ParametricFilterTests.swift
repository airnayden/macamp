import AudioEngine
import AVFAudio
import Foundation
import Testing

@Suite("ParametricFilter")
struct ParametricFilterTests {
    // MARK: - Q → bandwidth (octaves)

    /// The plan's closed form, implemented independently of the shipping code
    /// so the assertion is a cross-check and not a tautology:
    ///
    /// `bw = ln(1 + 1/(2Q²) + √(((2Q²+1)/Q²)²/4 − 1)) / ln 2`
    private static func referenceBandwidth(_ qFactor: Double) -> Double {
        let qSquared = qFactor * qFactor
        let shifted = 1 + 1 / (2 * qSquared)
        let ratio = (2 * qSquared + 1) / qSquared
        return log(shifted + (ratio * ratio / 4 - 1).squareRoot()) / log(2)
    }

    /// Reference values computed from the closed form above to 4 dp.
    private static let bandwidthReferences: [(qFactor: Double, octaves: Double)] = [
        (0.50, 2.5431),
        (0.70, 1.9169),
        (2.0.squareRoot() / 2, 1.9000),
        (1.00, 1.3885),
        (1.42, 0.9961),
        (2.00, 0.7140),
        (3.96, 0.3634),
        (5.75, 0.2506),
        (10.0, 0.1442),
    ]

    @Test("Q → bandwidth matches the closed-form reference values to 4 dp")
    func bandwidthMatchesReferences() {
        for (qFactor, octaves) in Self.bandwidthReferences {
            let filter = ParametricFilter(type: .peaking, frequency: 1000, gainDB: 0, qFactor: qFactor)
            let rounded = (filter.bandwidthInOctaves * 10000).rounded() / 10000
            #expect(rounded == octaves, "Q \(qFactor) → \(filter.bandwidthInOctaves) octaves")
        }
    }

    @Test("Q → bandwidth agrees with the closed form to machine precision")
    func bandwidthAgreesWithClosedForm() {
        for qFactor in stride(from: 0.2, through: 12.0, by: 0.1) {
            let filter = ParametricFilter(type: .peaking, frequency: 1000, gainDB: 0, qFactor: qFactor)
            let difference = abs(filter.bandwidthInOctaves - Self.referenceBandwidth(qFactor))
            #expect(difference < 1e-9, "Q \(qFactor) diverged by \(difference)")
        }
    }

    @Test("bandwidth is monotonically decreasing in Q")
    func bandwidthIsMonotonic() {
        var previous = Double.infinity
        for qFactor in stride(from: 0.2, through: 12.0, by: 0.1) {
            let octaves = ParametricFilter(type: .peaking, frequency: 1000, gainDB: 0, qFactor: qFactor)
                .bandwidthInOctaves
            #expect(octaves < previous)
            previous = octaves
        }
    }

    // MARK: - AVAudioUnitEQ parameter clamping

    @Test("auBandwidth clamps into the AU's documented 0.05 … 5.0 octave range")
    func auBandwidthClamped() {
        let veryWide = ParametricFilter(type: .peaking, frequency: 1000, gainDB: 0, qFactor: 0.05)
        let verySharp = ParametricFilter(type: .peaking, frequency: 1000, gainDB: 0, qFactor: 400)
        #expect(veryWide.bandwidthInOctaves > 5.0)
        #expect(veryWide.auBandwidth == 5.0)
        #expect(verySharp.bandwidthInOctaves < 0.05)
        #expect(verySharp.auBandwidth == 0.05)
    }

    @Test("a non-positive Q degrades to the widest legal bandwidth instead of NaN")
    func nonPositiveQIsSafe() {
        for qFactor in [0.0, -1.0] {
            let filter = ParametricFilter(type: .peaking, frequency: 1000, gainDB: 0, qFactor: qFactor)
            #expect(filter.bandwidthInOctaves == ParametricEQLimits.bandwidthRange.upperBound)
            #expect(filter.auBandwidth.isFinite)
        }
    }

    @Test("auGain clamps into the AU's documented −96 … +24 dB range")
    func auGainClamped() {
        #expect(ParametricFilter(type: .peaking, frequency: 1000, gainDB: 120, qFactor: 1).auGain == 24)
        #expect(ParametricFilter(type: .peaking, frequency: 1000, gainDB: -200, qFactor: 1).auGain == -96)
        #expect(ParametricFilter(type: .peaking, frequency: 1000, gainDB: 6.5, qFactor: 1).auGain == 6.5)
    }

    // MARK: - SDK type mapping

    @Test("PK / LSC / HSC map onto .parametric / .lowShelf / .highShelf")
    func filterTypeMapping() {
        #expect(ParametricFilterType.peaking.avFilterType == .parametric)
        #expect(ParametricFilterType.lowShelf.avFilterType == .lowShelf)
        #expect(ParametricFilterType.highShelf.avFilterType == .highShelf)
    }

    @Test("raw values are the AutoEq wire tokens and only the shelves report isShelf")
    func rawValuesAndShelfFlag() {
        #expect(ParametricFilterType.peaking.rawValue == "PK")
        #expect(ParametricFilterType.lowShelf.rawValue == "LSC")
        #expect(ParametricFilterType.highShelf.rawValue == "HSC")
        #expect(ParametricFilterType.peaking.isShelf == false)
        #expect(ParametricFilterType.lowShelf.isShelf)
        #expect(ParametricFilterType.highShelf.isShelf)
        #expect(ParametricFilterType.allCases.count == 3)
    }

    @Test("the legacy LS / HS tokens are not decodable as filter types")
    func legacyTokensAreNotTypes() {
        #expect(ParametricFilterType(rawValue: "LS") == nil)
        #expect(ParametricFilterType(rawValue: "HS") == nil)
    }

    // MARK: - Documented shelf-slope limitation

    @Test("only a shelf whose Q deviates from 0.71 by more than 20% is flagged")
    func shelfSlopeApproximationFlag() {
        let reference = ParametricFilter.referenceShelfQ
        let inside = [reference, 0.70, reference * 0.81, reference * 1.19]
        let outside = [reference * 0.79, reference * 1.21, 0.3, 2.0]

        for qFactor in inside {
            let filter = ParametricFilter(type: .lowShelf, frequency: 105, gainDB: 6, qFactor: qFactor)
            #expect(filter.isShelfSlopeApproximated == false, "Q \(qFactor) should be inside tolerance")
        }
        for qFactor in outside {
            let filter = ParametricFilter(type: .highShelf, frequency: 10000, gainDB: -2, qFactor: qFactor)
            #expect(filter.isShelfSlopeApproximated, "Q \(qFactor) should be outside tolerance")
        }
    }

    @Test("a peaking filter is never flagged — the AU honours its bandwidth exactly")
    func peakingIsNeverFlagged() {
        for qFactor in [0.1, 0.71, 1.0, 20.0] {
            let filter = ParametricFilter(type: .peaking, frequency: 1000, gainDB: 6, qFactor: qFactor)
            #expect(filter.isShelfSlopeApproximated == false)
        }
    }

    @Test("the tolerance band is exactly 0.568 … 0.852")
    func toleranceBandBounds() {
        #expect(ParametricFilter.referenceShelfQ == 0.71)
        #expect(ParametricFilter.shelfQTolerance == 0.20)
        let lower = ParametricFilter.referenceShelfQ * (1 - ParametricFilter.shelfQTolerance)
        let upper = ParametricFilter.referenceShelfQ * (1 + ParametricFilter.shelfQTolerance)
        #expect(abs(lower - 0.568) < 1e-12)
        #expect(abs(upper - 0.852) < 1e-12)
    }

    // MARK: - Configuration

    @Test("a configuration reports every approximated shelf by index")
    func configurationReportsApproximatedShelves() {
        let config = ParametricEQConfiguration(
            filters: [
                ParametricFilter(type: .peaking, frequency: 1000, gainDB: 3, qFactor: 4.0),
                ParametricFilter(type: .lowShelf, frequency: 105, gainDB: 6, qFactor: 0.70),
                ParametricFilter(type: .highShelf, frequency: 10000, gainDB: -2, qFactor: 1.5),
            ],
            preampDB: -6.1
        )
        #expect(config.hasApproximatedShelfSlope)
        #expect(config.approximatedShelfFilterIndices == [2])
    }

    @Test("bypass is empty and does not collide with Optional.none")
    func bypassIsEmpty() {
        #expect(ParametricEQConfiguration.bypass.isEmpty)
        #expect(ParametricEQConfiguration.bypass.filters.isEmpty)
        #expect(ParametricEQConfiguration.bypass.preampDB == 0)
        let optional: ParametricEQConfiguration? = ParametricEQConfiguration.bypass
        #expect(optional != nil)
    }

    @Test("a preamp alone is not an empty configuration")
    func preampAloneIsNotEmpty() {
        #expect(ParametricEQConfiguration(filters: [], preampDB: -6.1).isEmpty == false)
    }

    @Test("the filter ceiling matches the parametric node's band capacity")
    func maximumFilterCount() {
        #expect(ParametricEQConfiguration.maximumFilterCount == 16)
    }

    // MARK: - Codable round-trip (todo 20 persists filters as JSON)

    @Test("a parsed configuration survives a JSON round-trip unchanged")
    func codableRoundTrip() throws {
        let original = try AutoEqProfileParser.parse(contentsOf: TestFixtures.sennheiserHD650)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ParametricEQConfiguration.self, from: data)
        #expect(decoded == original)
    }

    @Test("filters encode as an array of objects keyed by the AutoEq wire tokens")
    func filterArrayEncoding() throws {
        let filters = [ParametricFilter(type: .lowShelf, frequency: 105, gainDB: 6.4, qFactor: 0.7)]
        let data = try JSONEncoder().encode(filters)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"LSC\""))
        let decoded = try JSONDecoder().decode([ParametricFilter].self, from: data)
        #expect(decoded == filters)
    }
}
