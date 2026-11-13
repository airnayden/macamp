import AudioEngine
import Foundation
import Testing

/// Self-checks for the RBJ reference model.
///
/// `RBJBiquad` is the independent oracle todo 19 measures `AVAudioUnitEQ`
/// against, so it needs its own proof: every assertion here is an analytically
/// known property of the cookbook filters, not a value read back out of the
/// implementation.
@Suite("RBJBiquad")
struct RBJBiquadTests {
    private static let sampleRate: Double = 44100

    private static func responseDB(_ filter: ParametricFilter, at frequency: Double) -> Double {
        RBJBiquad
            .make(for: filter, sampleRate: sampleRate)
            .responseDB(atFrequency: frequency, sampleRate: sampleRate)
    }

    // MARK: - Peaking

    @Test("a peaking filter's response at Fc is exactly its gain")
    func peakingHitsGainAtCenter() {
        for gainDB in [-12.0, -6.0, -1.5, 1.5, 6.0, 12.0] {
            for qFactor in [0.5, 1.0, 4.0] {
                let filter = ParametricFilter(type: .peaking, frequency: 1000, gainDB: gainDB, qFactor: qFactor)
                let measured = Self.responseDB(filter, at: 1000)
                #expect(abs(measured - gainDB) < 1e-9, "gain \(gainDB) Q \(qFactor) measured \(measured)")
            }
        }
    }

    @Test("a peaking filter is transparent far from Fc")
    func peakingIsTransparentFarFromCenter() {
        let filter = ParametricFilter(type: .peaking, frequency: 1000, gainDB: 6, qFactor: 1.0)
        #expect(abs(Self.responseDB(filter, at: 20)) < 0.05)
        #expect(abs(Self.responseDB(filter, at: 10000)) < 0.05)
    }

    @Test("a zero-gain filter is an identity at every frequency")
    func zeroGainIsIdentity() {
        for type in ParametricFilterType.allCases {
            let filter = ParametricFilter(type: type, frequency: 1000, gainDB: 0, qFactor: 0.9)
            for frequency in [30.0, 250.0, 1000.0, 5000.0, 18000.0] {
                #expect(abs(Self.responseDB(filter, at: frequency)) < 1e-9, "\(type) at \(frequency) Hz")
            }
        }
    }

    @Test("a narrower peaking filter is more selective than a wider one")
    func higherQIsNarrower() {
        let wide = ParametricFilter(type: .peaking, frequency: 1000, gainDB: 6, qFactor: 0.5)
        let narrow = ParametricFilter(type: .peaking, frequency: 1000, gainDB: 6, qFactor: 8.0)
        #expect(Self.responseDB(wide, at: 500) > Self.responseDB(narrow, at: 500))
        #expect(Self.responseDB(wide, at: 2000) > Self.responseDB(narrow, at: 2000))
    }

    // MARK: - Shelves

    @Test("a low shelf reaches its full gain on the plateau and half of it at Fc")
    func lowShelfPlateauAndCorner() {
        let filter = ParametricFilter(type: .lowShelf, frequency: 500, gainDB: 6, qFactor: 0.70)
        #expect(abs(Self.responseDB(filter, at: 62.5) - 6) < 0.01)
        #expect(abs(Self.responseDB(filter, at: 500) - 3) < 0.01)
        #expect(abs(Self.responseDB(filter, at: 16000)) < 0.05)
    }

    @Test("a high shelf reaches its full gain on the plateau and half of it at Fc")
    func highShelfPlateauAndCorner() {
        let filter = ParametricFilter(type: .highShelf, frequency: 2000, gainDB: -6, qFactor: 0.70)
        #expect(abs(Self.responseDB(filter, at: 16000) + 6) < 0.01)
        #expect(abs(Self.responseDB(filter, at: 2000) + 3) < 0.01)
        #expect(abs(Self.responseDB(filter, at: 40)) < 0.05)
    }

    /// Pins the measurement the plan's round-2 revision is based on: one octave
    /// below Fc a `Q 0.70` shelf still sits on the transition slope and reads
    /// only ≈ +5.6 dB, whereas Fc/8 is deep enough in the plateau to read the
    /// full +6 dB. Todo 19's shelf acceptance case therefore measures at Fc/8.
    @Test("a shelf's transition slope is still audible one octave below Fc")
    func shelfTransitionSlopeAtOneOctave() {
        let filter = ParametricFilter(type: .lowShelf, frequency: 500, gainDB: 6, qFactor: 0.70)
        let oneOctaveBelow = Self.responseDB(filter, at: 250)
        #expect(abs(oneOctaveBelow - 5.599034) < 1e-5)
        #expect(oneOctaveBelow < Self.responseDB(filter, at: 62.5))
    }

    // MARK: - Configuration composition

    @Test("series filters add in dB and the preamp offsets the whole curve")
    func configurationResponseAddsInDecibels() {
        let low = ParametricFilter(type: .peaking, frequency: 200, gainDB: 4, qFactor: 1.0)
        let high = ParametricFilter(type: .peaking, frequency: 6000, gainDB: -3, qFactor: 1.0)
        let config = ParametricEQConfiguration(filters: [low, high], preampDB: -4)

        for frequency in [100.0, 200.0, 1000.0, 6000.0, 12000.0] {
            let expected = Self.responseDB(low, at: frequency) + Self.responseDB(high, at: frequency)
            let combined = config.filterResponseDB(atFrequency: frequency, sampleRate: Self.sampleRate)
            #expect(abs(combined - expected) < 1e-12, "at \(frequency) Hz")
            let withPreamp = config.responseDB(atFrequency: frequency, sampleRate: Self.sampleRate)
            #expect(abs(withPreamp - (expected - 4)) < 1e-12, "at \(frequency) Hz with preamp")
        }
    }

    @Test("an empty configuration has a flat response equal to its preamp")
    func emptyConfigurationIsFlat() {
        #expect(ParametricEQConfiguration.bypass.responseDB(atFrequency: 1000, sampleRate: Self.sampleRate) == 0)
        let trimmed = ParametricEQConfiguration(filters: [], preampDB: -6.1)
        #expect(trimmed.responseDB(atFrequency: 1000, sampleRate: Self.sampleRate) == -6.1)
    }

    @Test("the committed AutoEq profile's modelled peak boost justifies its preamp")
    func fixtureBoostIsCoveredByPreamp() throws {
        let config = try AutoEqProfileParser.parse(contentsOf: TestFixtures.sennheiserHD650)
        let peakBoost = stride(from: 20.0, through: 20000.0, by: 5.0)
            .map { config.filterResponseDB(atFrequency: $0, sampleRate: Self.sampleRate) }
            .max() ?? 0
        #expect(peakBoost > 0)
        #expect(config.preampDB + peakBoost <= 0.2, "preamp \(config.preampDB) vs peak boost \(peakBoost)")
    }
}
