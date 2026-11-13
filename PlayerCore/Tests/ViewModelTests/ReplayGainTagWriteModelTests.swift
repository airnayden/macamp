// ReplayGainTagWriteModelTests — the partition the confirmation sheet shows is the
// partition the writer acts on, and nothing reaches a file that was not confirmed.
//
// The refusal assertions are per-reason rather than per-count on purpose: the whole
// point of ``ReplayGainTagUnsupportedReason`` is that "skipped" is three different
// facts, and a test that only counted them would pass while the sheet told an M4A
// owner nothing actionable.
import Foundation
import Metadata
import Persistence
import Services
import Testing
import ViewModels

@MainActor
@Suite("ReplayGainTagWritePlanTests")
struct ReplayGainTagWritePlanTests {
    @Test("the plan partitions a selection by refusal reason")
    func planPartitionsByReason() {
        let plan = ReplayGainTagWritePlan.make(for: TagTargets.mixed)

        #expect(plan.eligible.map(\.filePath) == ["/m/a.mp3", "/m/b.flac"])
        #expect(plan.eligibleCount == 2)
        #expect(plan.skippedCount == 6)
        #expect(plan.skipped == [
            ReplayGainTagSkip(reason: .oggFamilyMayCarryR128, count: 2),
            ReplayGainTagSkip(reason: .mp4BackendDiscardsTags, count: 2),
            ReplayGainTagSkip(reason: .formatNotVerified, count: 2),
        ])
    }

    /// A table selection is a `Set`, which iterates nondeterministically; a plan
    /// that listed the same file twice would rewrite it twice.
    @Test("the plan de-duplicates by track id and keeps display order")
    func planDeduplicatesByTrackId() {
        let targets = [
            ReplayGainTagTarget(trackId: 2, filePath: "/m/b.flac"),
            ReplayGainTagTarget(trackId: 1, filePath: "/m/a.mp3"),
            ReplayGainTagTarget(trackId: 2, filePath: "/m/b.flac"),
        ]

        let plan = ReplayGainTagWritePlan.make(for: targets)

        #expect(plan.eligible.map(\.trackId) == [2, 1])
    }

    /// The failure path the sheet's disabled button rests on.
    @Test("a plan with nothing eligible cannot be confirmed")
    func aPlanWithNothingEligibleCannotBeConfirmed() {
        let plan = ReplayGainTagWritePlan.make(for: TagTargets.refusedOnly)

        #expect(plan.canConfirm == false)
        #expect(plan.eligibleCount == 0)
        #expect(plan.skippedCount == 3)
    }

    @Test("a plan with an eligible file can be confirmed")
    func aPlanWithAnEligibleFileCanBeConfirmed() {
        let plan = ReplayGainTagWritePlan.make(for: TagTargets.mixed)

        #expect(plan.canConfirm)
    }
}

@MainActor
@Suite("ReplayGainTagWriteModelTests")
struct ReplayGainTagWriteModelTests {
    /// The acceptance criterion: only the allow-listed formats are written, and
    /// the refused ones never reach the writer at all.
    @Test("a confirmed write reaches only the eligible formats")
    func writeReachesOnlyEligibleFormats() async {
        let writer = RecordingTagWriter()
        let model = ReplayGainTagWriteModel(loudness: StubLoudnessCache.measuredAll, writer: writer)
        let plan = model.plan(for: TagTargets.mixed)

        let outcome = await model.write(plan)

        #expect(writer.paths == ["/m/a.mp3", "/m/b.flac"])
        #expect(outcome.written == 2)
        #expect(outcome.failed == 0)
        #expect(outcome.unmeasured == 0)
    }

    /// The failure path, proven at the model rather than only at the button: a
    /// keyboard route to a disabled control must not get past it either.
    @Test("a plan with nothing eligible writes nothing at all")
    func aPlanWithNothingEligibleWritesNothing() async {
        let writer = RecordingTagWriter()
        let model = ReplayGainTagWriteModel(loudness: StubLoudnessCache.measuredAll, writer: writer)
        let plan = model.plan(for: TagTargets.refusedOnly)

        let outcome = await model.write(plan)

        #expect(writer.paths.isEmpty)
        #expect(outcome == .nothing)
    }

    /// The conversion table todo 12 recorded, asserted field by field.
    @Test("the written values follow the documented conversion")
    func writtenValuesFollowTheConversion() async {
        let writer = RecordingTagWriter()
        let model = ReplayGainTagWriteModel(loudness: StubLoudnessCache.measuredAll, writer: writer)
        let plan = model.plan(for: [ReplayGainTagTarget(trackId: 1, filePath: "/m/a.mp3")])

        await model.write(plan)

        #expect(writer.values.count == 1)
        let values = writer.values.first
        #expect(values?.trackGainDB == ReplayGainSynthesis.gainDB(forIntegratedLUFS: -14.5))
        #expect(values?.trackPeak == 0.97)
        #expect(values?.albumGainDB == ReplayGainSynthesis.gainDB(forIntegratedLUFS: -12))
        #expect(values?.albumPeak == 0.99)
    }

    /// An eligible file MacAMP never measured carries nothing true to say, so its
    /// on-disk tags are left exactly as they were rather than overwritten with a
    /// claim that the file sits at reference.
    @Test("an unmeasured eligible file is left untouched")
    func anUnmeasuredEligibleFileIsLeftUntouched() async {
        let writer = RecordingTagWriter()
        let model = ReplayGainTagWriteModel(loudness: StubLoudnessCache.empty, writer: writer)
        let plan = model.plan(for: [ReplayGainTagTarget(trackId: 1, filePath: "/m/a.mp3")])

        let outcome = await model.write(plan)

        #expect(writer.paths.isEmpty)
        #expect(outcome.unmeasured == 1)
        #expect(outcome.written == 0)
    }

    @Test("a refusing writer is counted as failed, not as written")
    func aRefusingWriterIsCountedAsFailed() async {
        let writer = RecordingTagWriter(failsEverything: true)
        let model = ReplayGainTagWriteModel(loudness: StubLoudnessCache.measuredAll, writer: writer)
        let plan = model.plan(for: TagTargets.mixed)

        let outcome = await model.write(plan)

        #expect(outcome.failed == 2)
        #expect(outcome.written == 0)
    }
}

// MARK: - Fixtures

private enum TagTargets {
    /// Two writable formats and two of each refusal reason.
    static let mixed: [ReplayGainTagTarget] = [
        ReplayGainTagTarget(trackId: 1, filePath: "/m/a.mp3"),
        ReplayGainTagTarget(trackId: 2, filePath: "/m/b.flac"),
        ReplayGainTagTarget(trackId: 3, filePath: "/m/c.opus"),
        ReplayGainTagTarget(trackId: 4, filePath: "/m/d.ogg"),
        ReplayGainTagTarget(trackId: 5, filePath: "/m/e.m4a"),
        ReplayGainTagTarget(trackId: 6, filePath: "/m/f.mp4"),
        ReplayGainTagTarget(trackId: 7, filePath: "/m/g.wav"),
        ReplayGainTagTarget(trackId: 8, filePath: "/m/h.aiff"),
    ]

    static let refusedOnly: [ReplayGainTagTarget] = [
        ReplayGainTagTarget(trackId: 3, filePath: "/m/c.opus"),
        ReplayGainTagTarget(trackId: 5, filePath: "/m/e.m4a"),
        ReplayGainTagTarget(trackId: 7, filePath: "/m/g.wav"),
    ]
}

/// Serves the same measured row for every id, or none at all.
private actor StubLoudnessCache: TrackLoudnessReading {
    private let record: TrackLoudnessRecord?

    init(record: TrackLoudnessRecord?) {
        self.record = record
    }

    static var measuredAll: StubLoudnessCache {
        StubLoudnessCache(record: TrackLoudnessRecord(
            trackId: 0,
            integratedLUFS: -14.5,
            truePeak: 0.97,
            albumLUFS: -12,
            albumPeak: 0.99,
            analysisVersion: LoudnessScanService.analysisVersion,
            fingerprint: TrackLoudnessFingerprint(fileSize: 1, mtime: 1),
            computedAt: 0
        ))
    }

    static var empty: StubLoudnessCache {
        StubLoudnessCache(record: nil)
    }

    func loudness(forTrackId trackId: Int64) async throws -> TrackLoudnessRecord? {
        guard var served = record else { return nil }
        served.trackId = trackId
        return served
    }
}

/// Records every file the writer was asked to rewrite, in call order.
///
/// `@unchecked Sendable` with a lock because ``ReplayGainTagWriting`` is a
/// synchronous `Sendable` protocol and the model calls it from a detached task.
private final class RecordingTagWriter: ReplayGainTagWriting, @unchecked Sendable {
    private let lock = NSLock()
    private let failsEverything: Bool
    private var recorded: [(path: String, values: ReplayGainTagValues)] = []

    init(failsEverything: Bool = false) {
        self.failsEverything = failsEverything
    }

    var paths: [String] {
        lock.withLock { recorded.map(\.path) }
    }

    var values: [ReplayGainTagValues] {
        lock.withLock { recorded.map(\.values) }
    }

    func writeReplayGainTags(_ values: ReplayGainTagValues, to url: URL) throws {
        if failsEverything {
            throw ReplayGainTagWriteError.noValuesToWrite(url: url)
        }
        lock.withLock { recorded.append((url.path, values)) }
    }
}
