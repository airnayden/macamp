// Locks the gating + normalization of the scrubber replay-heat model (plan todo 12).
//
// Everything here runs against ``FakePlaySegmentHeatRepository`` — no GRDB — so the
// two things that decide whether the overlay appears at all (a row must exist, and
// it must clear ``ReplayHeatAnalysis/hasTrustworthyShape(totalPasses:buckets:)``)
// are asserted directly rather than inferred from a database fixture. The fake also
// counts reads that were serviced on the main thread, which is what turns "the read
// runs off-main" from a claim in a doc comment into a failing test.
import Foundation
import Persistence
import PlayerCoreTestSupport
import Testing
import ViewModels

@MainActor
@Suite("ScrubberHeatViewModelTests")
struct ScrubberHeatViewModelTests {
    private static let profileId: Int64 = 1
    private static let trackId: Int64 = 77

    // MARK: Normalization

    @Test("a seeded row publishes one intensity per bucket, peaking at exactly 1.0")
    func seededRowPublishesNormalizedIntensities() async throws {
        var buckets = [UInt32](repeating: 0, count: PlaySegmentHeatRecord.bucketCount)
        buckets[10] = 2
        buckets[42] = 8
        buckets[99] = 4
        let model = try makeModel(buckets: buckets, totalPasses: 5)

        await model.load(profileId: Self.profileId, trackId: Self.trackId)

        let heat = try #require(model.heat)
        #expect(heat.count == PlaySegmentHeatRecord.bucketCount)
        #expect(heat[42] == 1.0)
        #expect(heat[10] == 0.25)
        #expect(heat[99] == 0.5)
        #expect(heat[0] == 0)
    }

    @Test("normalization scales by the row's own maximum")
    func normalizationScalesByTheRowMaximum() {
        let normalized = ScrubberHeatViewModel.normalized([0, 1, 2, 4] as [UInt32])
        #expect(normalized == [0, 0.25, 0.5, 1.0])
    }

    @Test("an all-zero row has no maximum to scale by and publishes nil")
    func allZeroRowPublishesNil() async throws {
        let buckets = [UInt32](repeating: 0, count: PlaySegmentHeatRecord.bucketCount)
        let model = try makeModel(buckets: buckets, totalPasses: 9)

        await model.load(profileId: Self.profileId, trackId: Self.trackId)

        #expect(model.heat == nil)
    }

    // MARK: The noise floor

    @Test("a row that clears neither half of the floor publishes nil")
    func belowTheNoiseFloorPublishesNil() async throws {
        let model = try makeModel(
            buckets: Self.thinBuckets,
            totalPasses: ScrubberHeatViewModel.minimumPasses - 1
        )

        await model.load(profileId: Self.profileId, trackId: Self.trackId)

        #expect(model.heat == nil)
    }

    @Test("exactly the minimum committed passes is enough — the floor is inclusive")
    func atTheNoiseFloorPublishesTheCurve() async throws {
        // Flat buckets on purpose: nothing here can clear the peak half, so this
        // isolates the passes half of the floor.
        let model = try makeModel(buckets: Self.flatBuckets, totalPasses: ScrubberHeatViewModel.minimumPasses)

        await model.load(profileId: Self.profileId, trackId: Self.trackId)

        #expect(model.heat?.count == PlaySegmentHeatRecord.bucketCount)
    }

    @Test("one sitting that replayed a passage still publishes the curve")
    func oneSittingWithAReplayedPassagePublishesTheCurve() async throws {
        // The user-reported case: one long sitting, several rewinds to the same
        // passage. One flush is one pass, so only the peak half can admit this.
        let model = try makeModel(buckets: Self.peakedBuckets, totalPasses: 1)

        await model.load(profileId: Self.profileId, trackId: Self.trackId)

        #expect(model.heat?.count == PlaySegmentHeatRecord.bucketCount)
        #expect(model.heat?[42] == 1.0)
    }

    @Test("one sitting whose busiest slice was heard twice publishes nil")
    func oneSittingBelowThePeakFloorPublishesNil() async throws {
        let model = try makeModel(buckets: Self.thinBuckets, totalPasses: 1)

        await model.load(profileId: Self.profileId, trackId: Self.trackId)

        #expect(model.heat == nil)
    }

    // MARK: Absent data

    @Test("a track this profile has never played publishes nil")
    func missingRowPublishesNil() async {
        let repository = FakePlaySegmentHeatRepository()
        let model = ScrubberHeatViewModel(repository: repository)

        await model.load(profileId: Self.profileId, trackId: Self.trackId)

        #expect(model.heat == nil)
        #expect(repository.recording.reads.count == 1)
    }

    @Test("another profile's row is not visible")
    func rowsAreProfileScoped() async throws {
        let model = try makeModel(buckets: Self.peakedBuckets, totalPasses: 9)

        await model.load(profileId: 42, trackId: Self.trackId)

        #expect(model.heat == nil)
    }

    @Test("a non-library track never touches the repository")
    func nilTrackIdSkipsTheRepository() async {
        let repository = FakePlaySegmentHeatRepository()
        let model = ScrubberHeatViewModel(repository: repository)

        await model.load(profileId: Self.profileId, trackId: nil)
        await model.load(profileId: Self.profileId, trackId: 0)

        #expect(model.heat == nil)
        #expect(repository.recording.reads.isEmpty)
    }

    @Test("a failed read degrades to nil rather than surfacing an error")
    func failedReadPublishesNil() async throws {
        let repository = FakePlaySegmentHeatRepository()
        let record = try FakePlaySegmentHeatRepository.record(
            profileId: Self.profileId,
            trackId: Self.trackId,
            buckets: Self.peakedBuckets,
            totalPasses: 9
        )
        repository.seed(record)
        repository.setReadShouldFail(true)
        let model = ScrubberHeatViewModel(repository: repository)

        await model.load(profileId: Self.profileId, trackId: Self.trackId)

        #expect(model.heat == nil)
    }

    // MARK: Lifecycle

    @Test("the read never runs on the main thread")
    func readRunsOffTheMainThread() async throws {
        let repository = FakePlaySegmentHeatRepository()
        let record = try FakePlaySegmentHeatRepository.record(
            profileId: Self.profileId,
            trackId: Self.trackId,
            buckets: Self.peakedBuckets,
            totalPasses: 9
        )
        repository.seed(record)
        let model = ScrubberHeatViewModel(repository: repository)

        await model.load(profileId: Self.profileId, trackId: Self.trackId)

        #expect(repository.recording.mainThreadReads == 0)
        #expect(repository.recording.reads.count == 1)
    }

    @Test("a track change clears the previous curve before the new one resolves")
    func trackChangeClearsThePreviousCurve() async throws {
        let model = try makeModel(buckets: Self.peakedBuckets, totalPasses: 9)
        await model.load(profileId: Self.profileId, trackId: Self.trackId)
        #expect(model.heat != nil)

        await model.load(profileId: Self.profileId, trackId: Self.trackId + 1)

        #expect(model.heat == nil)
    }

    @Test("clear drops the curve")
    func clearDropsTheCurve() async throws {
        let model = try makeModel(buckets: Self.peakedBuckets, totalPasses: 9)
        await model.load(profileId: Self.profileId, trackId: Self.trackId)
        #expect(model.heat != nil)

        model.clear()

        #expect(model.heat == nil)
    }
}

// MARK: - Fixtures

private extension ScrubberHeatViewModelTests {
    nonisolated static var peakedBuckets: [UInt32] {
        var buckets = [UInt32](repeating: 1, count: PlaySegmentHeatRecord.bucketCount)
        buckets[42] = 12
        return buckets
    }

    /// Every bucket heard once — a shape the peak half of the floor can never admit.
    nonisolated static var flatBuckets: [UInt32] {
        [UInt32](repeating: 1, count: PlaySegmentHeatRecord.bucketCount)
    }

    /// A hint of a hook, one listen short of being corroborated.
    nonisolated static var thinBuckets: [UInt32] {
        var buckets = [UInt32](repeating: 1, count: PlaySegmentHeatRecord.bucketCount)
        buckets[42] = 2
        return buckets
    }

    func makeModel(buckets: [UInt32], totalPasses: Int) throws -> ScrubberHeatViewModel {
        let repository = FakePlaySegmentHeatRepository()
        let record = try FakePlaySegmentHeatRepository.record(
            profileId: Self.profileId,
            trackId: Self.trackId,
            buckets: buckets,
            totalPasses: totalPasses
        )
        repository.seed(record)
        return ScrubberHeatViewModel(repository: repository)
    }
}
