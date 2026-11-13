import Foundation
import GRDB
import Persistence
import PlayerCoreTestSupport
import Services
import Testing

/// ``MixGeneratorService`` end to end: scripted candidate pools, a REAL library
/// and a real ``MixCandidateResolver`` over an in-memory v16 database.
///
/// The pools are faked because their own suites already prove them; the resolver
/// is not, because the promise under test — "the same spec and seed produce the
/// same draft" — depends on the chunked `resolvedTracks` read staying ordered,
/// which only a real database can demonstrate.
@Suite("MixGeneratorServiceTests")
struct MixGeneratorServiceTests {
    private static let profileId = ProfileRecord.guestID

    @Test("The same spec and seed produce byte-identical drafts, run twice")
    func repeatedGenerationIsIdentical() async throws {
        let fixture = try MixGeneratorFixture()
        // Three artists over forty tracks: enough to make the de-clump actually
        // re-order the pool, and still satisfiable at the default spacing of 3.
        try fixture.library(ids: Array(100 ... 139), artistCount: 3)
        fixture.similarity.setCoOccurring(MixGeneratorFixture.neighbours(ids: Array(100 ... 139)))
        let spec = MixSpec(
            profileId: Self.profileId,
            source: .similaritySeed(trackId: 42),
            targetCount: 25,
            seed: 7
        )

        let first = try await fixture.service.generate(spec)
        let second = try await fixture.service.generate(spec)

        #expect(first == second)
        #expect(MixGeneratorFixture.signature(first) == MixGeneratorFixture.signature(second))
        #expect(first.entries.count == 25)
        #expect(first.underfilled == false)
        #expect(first.artistSpacingSatisfied)
        // A golden order, not just a self-comparison: SplitMix64 is pure integer
        // arithmetic and every sort in the pipeline uses a TOTAL comparator, so
        // this sequence is reproducible across machines and across builds — which
        // is the property a preview-then-apply flow actually depends on.
        #expect(first.trackIds == MixGeneratorFixture.goldenSimilarityOrder)
    }

    @Test("A different seed reorders the same pool")
    func seedChangesTheOrder() async throws {
        let fixture = try MixGeneratorFixture()
        try fixture.library(ids: Array(100 ... 119))
        // A flat pool is where the seed has full authority — distinct scores are
        // authoritative and must survive any seed.
        fixture.rediscovery.seed(neverPlayed: MixGeneratorFixture.rediscovered(ids: Array(100 ... 119)))
        let spec = MixSpec(
            profileId: Self.profileId,
            source: .rediscovery(list: .neverPlayed),
            targetCount: 10,
            seed: 7
        )
        var reseeded = spec
        reseeded.seed = 8

        let ordered = try await fixture.service.generate(spec).trackIds
        let alternate = try await fixture.service.generate(reseeded).trackIds

        #expect(ordered != alternate)
        // The alphabetical `(sortTitle, id)` walk order must not survive.
        #expect(ordered != Array(100 ... 109))
    }

    @Test("A pool smaller than the target returns everything available, flagged underfilled")
    func smallPoolIsUnderfilledAndNeverPadded() async throws {
        let fixture = try MixGeneratorFixture()
        try fixture.library(ids: Array(100 ... 109))
        fixture.similarity.setCoOccurring(MixGeneratorFixture.neighbours(ids: Array(100 ... 109)))
        let spec = MixSpec(
            profileId: Self.profileId,
            source: .similaritySeed(trackId: 42),
            targetCount: 25,
            seed: 7
        )

        let draft = try await fixture.service.generate(spec)

        #expect(draft.entries.count == 10)
        #expect(draft.underfilled)
        #expect(Set(draft.trackIds).count == 10)
        #expect(draft.trackIds.sorted() == Array(100 ... 109))
    }

    @Test("An empty pool yields an empty draft rather than an error")
    func emptyPoolYieldsAnEmptyDraft() async throws {
        let fixture = try MixGeneratorFixture()
        let spec = MixSpec(profileId: Self.profileId, source: .similaritySeed(trackId: 42), seed: 7)

        let draft = try await fixture.service.generate(spec)

        #expect(draft.isEmpty)
        #expect(draft.underfilled)
        #expect(draft.nameHint.trackCount == 0)
    }

    @Test("A candidate with no library row is dropped, never proposed")
    func unresolvableCandidateIsDropped() async throws {
        let fixture = try MixGeneratorFixture()
        try fixture.library(ids: [100, 101])
        // `playEvent.trackId` is a bare integer, so co-session similarity can
        // legitimately name a track whose row has since been removed.
        fixture.similarity.setCoOccurring(MixGeneratorFixture.neighbours(ids: [100, 999, 101]))
        let spec = MixSpec(profileId: Self.profileId, source: .similaritySeed(trackId: 42), seed: 7)

        let draft = try await fixture.service.generate(spec)

        #expect(draft.trackIds.sorted() == [100, 101])
    }

    @Test("Missing and external-offline tracks are never proposed")
    func unavailableTrackIsNeverProposed() async throws {
        let fixture = try MixGeneratorFixture()
        try fixture.library(ids: [100, 101])
        try fixture.library(ids: [102], availability: .missing)
        try fixture.library(ids: [103], availability: .externalOffline)
        // Co-session similarity scores from `playEvent`, which records no
        // availability, so this is the source that can name an unplayable file.
        fixture.similarity.setCoOccurring(MixGeneratorFixture.neighbours(ids: [100, 102, 103, 101]))
        let spec = MixSpec(profileId: Self.profileId, source: .similaritySeed(trackId: 42), seed: 7)

        let draft = try await fixture.service.generate(spec)

        #expect(draft.trackIds.sorted() == [100, 101])
    }

    @Test("The target duration is honoured to within one track")
    func targetDurationIsHonoured() async throws {
        let fixture = try MixGeneratorFixture()
        try fixture.library(ids: Array(100 ... 119), duration: 180)
        fixture.similarity.setCoOccurring(MixGeneratorFixture.neighbours(ids: Array(100 ... 119)))
        let spec = MixSpec(
            profileId: Self.profileId,
            source: .similaritySeed(trackId: 42),
            targetCount: 20,
            targetDuration: 1000,
            seed: 7
        )

        let draft = try await fixture.service.generate(spec)

        #expect(draft.entries.count == 5)
        #expect(draft.totalDuration == 900)
        #expect(draft.totalDuration <= 1000)
        #expect(draft.totalDuration + 180 > 1000)
    }

    @Test("Artist spacing holds when the library has enough artists")
    func spacingHoldsOnAVariedLibrary() async throws {
        let fixture = try MixGeneratorFixture()
        try fixture.library(ids: Array(100 ... 119), artistCount: 5)
        fixture.similarity.setCoOccurring(MixGeneratorFixture.neighbours(ids: Array(100 ... 119)))
        let spec = MixSpec(
            profileId: Self.profileId,
            source: .similaritySeed(trackId: 42),
            targetCount: 12,
            constraints: MixConstraints(artistSpacing: 3, energyArc: false),
            seed: 7
        )

        let draft = try await fixture.service.generate(spec)

        #expect(draft.artistSpacingSatisfied)
        #expect(draft.energyArcApplied == false)
    }

    @Test("Ten tracks by two artists: the draft reports the spacing it could not honour")
    func adversarialLibraryFlagsTheSpacing() async throws {
        let fixture = try MixGeneratorFixture()
        try fixture.library(ids: Array(100 ... 109), artistCount: 2)
        fixture.similarity.setCoOccurring(MixGeneratorFixture.neighbours(ids: Array(100 ... 109)))
        let spec = MixSpec(
            profileId: Self.profileId,
            source: .similaritySeed(trackId: 42),
            targetCount: 10,
            constraints: MixConstraints(artistSpacing: 3, energyArc: false),
            seed: 7
        )

        let draft = try await fixture.service.generate(spec)

        #expect(draft.entries.count == 10)
        #expect(draft.artistSpacingSatisfied == false)
    }

    @Test("The energy arc engages once the library is analysed")
    func arcEngagesOnAnAnalysedLibrary() async throws {
        let fixture = try MixGeneratorFixture()
        let ids = Array(Int64(100) ... 109)
        try fixture.library(ids: ids)
        for (index, trackId) in ids.enumerated() {
            try fixture.feature(trackId: trackId, energy: Double(index + 1) / 10)
        }
        fixture.similarity.setCoOccurring(MixGeneratorFixture.neighbours(ids: ids))
        let spec = MixSpec(
            profileId: Self.profileId,
            source: .similaritySeed(trackId: 42),
            targetCount: 9,
            seed: 7
        )

        let draft = try await fixture.service.generate(spec)

        #expect(draft.energyArcApplied)
        let curve = draft.entries.map { $0.energy ?? 0 }
        let maximum = try #require(curve.max())
        let peak = try #require(curve.firstIndex(of: maximum))
        #expect(MixFixture.isNonDecreasing(Array(curve[...peak])))
        #expect(MixFixture.isNonIncreasing(Array(curve[peak...])))
    }

    @Test("An unanalysed library keeps the de-clumped rank order")
    func arcIsSkippedWithoutFeatures() async throws {
        let fixture = try MixGeneratorFixture()
        try fixture.library(ids: Array(100 ... 109))
        fixture.similarity.setCoOccurring(MixGeneratorFixture.neighbours(ids: Array(100 ... 109)))
        let spec = MixSpec(profileId: Self.profileId, source: .similaritySeed(trackId: 42), seed: 7)

        let draft = try await fixture.service.generate(spec)

        #expect(draft.energyArcApplied == false)
        #expect(draft.entries.allSatisfy { $0.energy == nil })
    }

    @Test("A nil daypart request resolves to the bucket it is now")
    func nilDaypartResolvesToTheCurrentBucket() async throws {
        let fixture = try MixGeneratorFixture(current: .night)
        try fixture.library(ids: Array(100 ... 104))
        fixture.dayparts.seed(.night, tracks: MixGeneratorFixture.daypartTracks(ids: Array(100 ... 104)))
        let spec = MixSpec(profileId: Self.profileId, source: .daypart(part: nil), targetCount: 5, seed: 7)

        let draft = try await fixture.service.generate(spec)

        #expect(draft.nameHint.daypart == .night)
        #expect(draft.nameHint.sourceKind == .daypart)
        #expect(draft.entries.allSatisfy { $0.provenance == .daypart(.night) })
    }

    @Test("Each source stamps its own provenance on every entry")
    func provenanceCarriesTheContributingSource() async throws {
        let fixture = try MixGeneratorFixture()
        try fixture.library(ids: Array(100 ... 104))
        fixture.rediscovery.seed(throwbacks: MixGeneratorFixture.rediscovered(ids: Array(100 ... 104)))
        let spec = MixSpec(
            profileId: Self.profileId,
            source: .rediscovery(list: .throwbacks),
            targetCount: 5,
            seed: 7
        )

        let draft = try await fixture.service.generate(spec)

        #expect(draft.entries.allSatisfy { $0.provenance == .throwback })
        #expect(draft.nameHint.sourceKind == .rediscovery)
        #expect(draft.nameHint.seedTrackId == nil)
    }

    @Test("A rules result keeps its own ordering and never re-materialises the playlist")
    func rulesResultPreservesItsOrder() async throws {
        let fixture = try MixGeneratorFixture()
        let ordered: [Int64] = [104, 100, 102, 101, 103]
        try fixture.library(ids: ordered)
        let spec = MixSpec(
            profileId: Self.profileId,
            source: .rulesResult(trackIds: ordered),
            targetCount: 5,
            constraints: MixConstraints(artistSpacing: 1, energyArc: false),
            seed: 7
        )

        let draft = try await fixture.service.generate(spec)

        #expect(draft.trackIds == ordered)
        #expect(draft.entries.allSatisfy { $0.provenance == .rulesResult })
        #expect(draft.nameHint.sourceKind == .rulesResult)
    }

    @Test("A similarity mix records its seed track in the name slot")
    func nameSlotCarriesTheSeed() async throws {
        let fixture = try MixGeneratorFixture()
        try fixture.library(ids: Array(100 ... 104))
        fixture.similarity.setCoOccurring(MixGeneratorFixture.neighbours(ids: Array(100 ... 104)))
        let spec = MixSpec(profileId: Self.profileId, source: .similaritySeed(trackId: 42), seed: 7)

        let draft = try await fixture.service.generate(spec)

        #expect(draft.nameHint.seedTrackId == 42)
        #expect(draft.nameHint.trackCount == draft.entries.count)
        #expect(draft.nameHint.daypart == nil)
    }
}
