import Foundation
import Services
import Testing

/// ``MixRanking``'s four steps, each asserted on its own.
///
/// Every case here is pure: no database, no clock, no service. The properties
/// under test — spacing, arc monotonicity, duration tolerance, seed determinism —
/// are claims about the ORDERING, so proving them on values rather than through
/// ``MixGeneratorService`` keeps a failure pointing at the step that broke.
@Suite("MixRankingTests")
struct MixRankingTests {
    // MARK: - Step 1: score order and the seeded tie-break

    @Test("Distinct scores rank highest first, whatever the seed")
    func distinctScoresIgnoreTheSeed() {
        let pool = (1 ... 5).map { MixFixture.candidate(id: Int64($0), score: Double($0)) }
        var quiet = MixRandom(seed: 7)
        var loud = MixRandom(seed: 999)

        let ordered = MixRanking.scoreOrdered(pool, using: &quiet)
        let reordered = MixRanking.scoreOrdered(pool, using: &loud)

        #expect(ordered.map(\.trackId) == [5, 4, 3, 2, 1])
        #expect(reordered.map(\.trackId) == [5, 4, 3, 2, 1])
    }

    @Test("A flat pool is shuffled reproducibly under one seed")
    func flatPoolIsSeededShuffled() {
        let pool = MixFixture.flatPool(ids: Array(1 ... 10))
        var firstRun = MixRandom(seed: 7)
        var secondRun = MixRandom(seed: 7)

        let ordered = MixRanking.scoreOrdered(pool, using: &firstRun).map(\.trackId)
        let repeated = MixRanking.scoreOrdered(pool, using: &secondRun).map(\.trackId)

        #expect(ordered == repeated)
        #expect(ordered.sorted() == Array(1 ... 10))
    }

    @Test("Different seeds break a flat pool differently — no alphabetical bias survives")
    func differentSeedsShuffleDifferently() {
        let pool = MixFixture.flatPool(ids: Array(1 ... 10))
        var firstRun = MixRandom(seed: 7)
        var secondRun = MixRandom(seed: 8)

        let ordered = MixRanking.scoreOrdered(pool, using: &firstRun).map(\.trackId)
        let alternate = MixRanking.scoreOrdered(pool, using: &secondRun).map(\.trackId)

        #expect(ordered != alternate)
        #expect(ordered != Array(1 ... 10))
    }

    @Test("The draw order depends on the candidate SET, not on how the pool was paged")
    func drawOrderIsIndependentOfInputOrder() {
        let pool = MixFixture.flatPool(ids: Array(1 ... 10))
        var forward = MixRandom(seed: 7)
        var backward = MixRandom(seed: 7)

        let ordered = MixRanking.scoreOrdered(pool, using: &forward).map(\.trackId)
        let fromReversed = MixRanking.scoreOrdered(Array(pool.reversed()), using: &backward).map(\.trackId)

        #expect(ordered == fromReversed)
    }

    // MARK: - Step 2: artist spacing

    @Test("Three artists, nine tracks: the spacing invariant holds exactly")
    func spacingHoldsWhenThePoolAllowsIt() {
        let pool = MixFixture.byArtist(["A": 3, "B": 3, "C": 3])

        let spaced = MixRanking.deClumped(pool, spacing: 3)

        #expect(MixRanking.spacingSatisfied(spaced, spacing: 3))
        #expect(MixFixture.artists(spaced) == ["A", "B", "C", "A", "B", "C", "A", "B", "C"])
    }

    @Test("Adversarial pool — ten tracks, two artists — degrades to strict alternation and is FLAGGED")
    func adversarialPoolDegradesToAlternation() {
        // Two artists cannot be three apart: every third slot must repeat one of
        // them. The documented compromise is the widest gap the pool can still
        // offer, which for two artists is strict alternation (gap 2).
        let pool = MixFixture.byArtist(["A": 5, "B": 5])

        let spaced = MixRanking.deClumped(pool, spacing: 3)

        #expect(spaced.count == 10)
        #expect(MixRanking.spacingSatisfied(spaced, spacing: 3) == false)
        #expect(MixRanking.spacingSatisfied(spaced, spacing: 2))
        #expect(MixFixture.artists(spaced) == ["A", "B", "A", "B", "A", "B", "A", "B", "A", "B"])
    }

    @Test("An untagged artist never counts as a clump")
    func untaggedArtistNeverClumps() {
        let pool = (1 ... 6).map { MixFixture.candidate(id: Int64($0), score: Double(10 - $0)) }

        let spaced = MixRanking.deClumped(pool, spacing: 3)

        #expect(MixRanking.spacingSatisfied(spaced, spacing: 3))
        #expect(spaced.map(\.trackId) == [1, 2, 3, 4, 5, 6])
    }

    @Test("De-clumping keeps score order when no artist ever repeats")
    func distinctArtistsPreserveScoreOrder() {
        let pool = MixFixture.byArtist(["A": 1, "B": 1, "C": 1, "D": 1])

        let spaced = MixRanking.deClumped(pool, spacing: 3)

        #expect(spaced.map(\.trackId) == pool.map(\.trackId))
    }

    // MARK: - Step 3: target count and duration

    @Test("Selection stops before the target duration is overshot — honoured to one track")
    func durationIsHonouredToWithinOneTrack() throws {
        let pool = (1 ... 8).map { MixFixture.candidate(id: Int64($0), score: Double(10 - $0), duration: 100) }

        let chosen = MixRanking.selected(pool, targetCount: 8, targetDuration: 250)

        let total = chosen.reduce(0.0) { $0 + ($1.duration ?? 0) }
        let next = try #require(pool.dropFirst(chosen.count).first?.duration)
        #expect(chosen.count == 2)
        #expect(total <= 250)
        #expect(total + next > 250)
    }

    @Test("A target shorter than any single track still yields one playable track")
    func firstTrackIsExemptFromTheDurationTarget() {
        let pool = [MixFixture.candidate(id: 1, score: 1, duration: 400)]

        let chosen = MixRanking.selected(pool, targetCount: 5, targetDuration: 100)

        #expect(chosen.map(\.trackId) == [1])
    }

    @Test("Target count caps the selection when no duration is asked for")
    func targetCountCapsTheSelection() {
        let pool = (1 ... 10).map { MixFixture.candidate(id: Int64($0), score: Double(20 - $0)) }

        let chosen = MixRanking.selected(pool, targetCount: 4, targetDuration: nil)

        #expect(chosen.map(\.trackId) == [1, 2, 3, 4])
    }

    // MARK: - Step 4: the energy arc

    @Test("The arc rises to a single peak and falls back")
    func arcIsMonotoneOnBothSidesOfThePeak() throws {
        let pool = MixFixture.byEnergy([0.5, 0.1, 0.4, 0.2, 0.3])

        let arced = try #require(MixRanking.energyArced(pool))

        let curve = arced.map { $0.energy ?? 0 }
        #expect(curve == [0.1, 0.3, 0.5, 0.4, 0.2])
        try MixFixture.expectArc(curve)
    }

    @Test("An arc over an even-length selection is still monotone either side of its peak")
    func arcHandlesEvenLengths() throws {
        let pool = MixFixture.byEnergy([0.4, 0.1, 0.3, 0.2])

        let arced = try #require(MixRanking.energyArced(pool))

        try MixFixture.expectArc(arced.map { $0.energy ?? 0 })
    }

    @Test("Thin analysis coverage skips the arc and preserves the incoming order")
    func thinCoverageSkipsTheArc() {
        // Three of five analysed is 0.6 — below the 0.8 gate.
        let pool = MixFixture.byEnergy([0.1, 0.2, 0.3, nil, nil])

        #expect(MixRanking.energyArced(pool) == nil)
    }

    @Test("Exactly the coverage threshold applies the arc")
    func thresholdCoverageAppliesTheArc() {
        let pool = MixFixture.byEnergy([0.1, 0.2, 0.3, 0.4, nil])

        #expect(MixRanking.energyArced(pool) != nil)
    }

    @Test("A selection shorter than three tracks cannot arc")
    func tooShortToArc() {
        #expect(MixRanking.energyArced(MixFixture.byEnergy([0.2, 0.8])) == nil)
    }

    @Test("An unanalysed track in an analysed selection sorts at the pool mean")
    func unanalysedTrackSortsAtTheMean() throws {
        let pool = MixFixture.byEnergy([0.1, 0.2, 0.9, 0.8, nil])

        let arced = try #require(MixRanking.energyArced(pool))

        // mean(0.1, 0.2, 0.9, 0.8) = 0.5, so track 5 sits third in the ascending
        // sort and lands on the peak of a five-slot arc.
        #expect(arced.map(\.trackId) == [1, 5, 3, 4, 2])
    }
}

// MARK: - Fixture

/// Candidate builders shared by the ranking cases.
enum MixFixture {
    static func candidate(
        id: Int64,
        score: Double,
        artistKey: String? = nil,
        duration: TimeInterval? = nil,
        energy: Double? = nil
    ) -> MixCandidate {
        MixCandidate(
            trackId: id,
            provenance: .coSession,
            score: score,
            artistKey: artistKey,
            duration: duration,
            energy: energy
        )
    }

    /// A pool whose scores are all equal — the shape
    /// ``RediscoveryProviding/neverPlayed(profileId:limit:)`` produces, and the
    /// only shape the seeded tie-break fully re-orders.
    static func flatPool(ids: [Int64]) -> [MixCandidate] {
        ids.map { candidate(id: $0, score: 1) }
    }

    /// One candidate per requested track, artist-BLOCKED and score-ordered — the
    /// hardest input for the de-clump to fix. Artists are emitted in sorted key
    /// order so the fixture cannot depend on dictionary iteration.
    static func byArtist(_ counts: [String: Int]) -> [MixCandidate] {
        var keys: [String] = []
        for key in counts.keys.sorted() {
            keys += Array(repeating: key, count: counts[key] ?? 0)
        }
        return keys.enumerated().map { index, key in
            candidate(id: Int64(index + 1), score: Double(keys.count - index), artistKey: key)
        }
    }

    /// Equally-scored candidates numbered from 1, carrying the given energies.
    static func byEnergy(_ energies: [Double?]) -> [MixCandidate] {
        energies.enumerated().map { index, energy in
            candidate(id: Int64(index + 1), score: 1, energy: energy)
        }
    }

    /// Asserts the curve rises to its maximum and falls away from it.
    static func expectArc(_ curve: [Double]) throws {
        let maximum = try #require(curve.max())
        let peak = try #require(curve.firstIndex(of: maximum))
        #expect(isNonDecreasing(Array(curve[...peak])))
        #expect(isNonIncreasing(Array(curve[peak...])))
    }

    static func artists(_ candidates: [MixCandidate]) -> [String] {
        candidates.map { $0.artistKey ?? "" }
    }

    static func isNonDecreasing(_ values: [Double]) -> Bool {
        zip(values, values.dropFirst()).allSatisfy { $0 <= $1 }
    }

    static func isNonIncreasing(_ values: [Double]) -> Bool {
        zip(values, values.dropFirst()).allSatisfy { $0 >= $1 }
    }
}
