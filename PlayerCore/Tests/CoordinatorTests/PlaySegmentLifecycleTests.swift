// PlaySegmentLifecycleTests — every way a play can end, in one table.
//
// The matrix is the point: the tracker is correct only if it commits exactly once
// per pass, with exactly the right buckets, for EVERY lifecycle the coordinator can
// produce — not just the happy natural end. Each row scripts the samples and signals
// that lifecycle delivers and states the totals it must produce.
import Foundation
import Persistence
import PlayerCoreTestSupport
@testable import Services
import Testing

/// What a lifecycle must leave behind: how many passes committed, which buckets they
/// filled (everything unlisted must be zero), and — where it matters — who owns them.
struct SegmentExpectation {
    var merges: Int
    var filled: [(ClosedRange<Int>, UInt32)] = []
    var profileIds: [Int64]?
}

/// One playback lifecycle, scripted against the tracker.
struct SegmentLifecycle: CustomTestStringConvertible {
    var name: String
    var script: @MainActor @Sendable (SegmentTrackerHarness) async -> Void
    var expected: SegmentExpectation

    var testDescription: String {
        name
    }
}

@MainActor
@Suite("PlaySegmentLifecycleTests")
struct PlaySegmentLifecycleTests {
    @Test("lifecycle matrix", arguments: SegmentLifecycle.matrix)
    func lifecycleCommitsExactly(_ lifecycle: SegmentLifecycle) async throws {
        let harness = try SegmentTrackerHarness()

        await lifecycle.script(harness)

        let merges = await harness.merges()
        #expect(merges.count == lifecycle.expected.merges)
        if let profileIds = lifecycle.expected.profileIds {
            #expect(merges.map(\.profileId) == profileIds)
        }
        var totals = [UInt32](repeating: 0, count: PlaySegmentHeatRecord.bucketCount)
        for merge in merges {
            for index in totals.indices {
                totals[index] += merge.deltas[index]
            }
        }
        #expect(totals == SegmentLifecycle.expand(lifecycle.expected.filled))
    }

    @Test("two repeat-one passes reach the real table as two counted passes")
    func repeatOneAccumulatesInTheDatabase() async throws {
        let database = try AppDatabase.makeEmpty()
        let repository = PlaySegmentHeatRepository(database)
        let track = SegmentTrackerHarness.track()
        let tracker = PlaySegmentTracker(
            heat: repository,
            tracks: TrackRepository(database),
            playhead: PlaySegmentPlayhead(
                currentTrack: { track },
                currentTime: { 0 },
                activeProfileId: { ProfileRecord.guestID }
            )
        )

        for _ in 0 ..< 2 {
            tracker.beginTrack(trackRef: track, profileId: ProfileRecord.guestID)
            var time: TimeInterval = 0
            while time <= 99 {
                tracker.ingest(sample: PlayheadSample(time: time, isPlaying: true))
                time += PlaySegmentTracker.sampleInterval
            }
            tracker.flush(signal: SegmentTrackerHarness.signal(.natural))
        }
        await tracker.flushAndWait()

        let row = try #require(try await repository.segmentHeat(
            profileId: ProfileRecord.guestID,
            trackId: SegmentTrackerHarness.trackId
        ))
        #expect(row.totalPasses == 2)
        #expect(try row.decodedBuckets().allSatisfy { $0 == 2 })
    }

    @Test("one transition reaches counters, recorder and tracker exactly once each")
    func fanOutReachesEveryConsumer() {
        let harness = PlayEventHarness()
        let counters = TrackStartCounter()
        let recorder = FakePlayEventRecorder()
        let tracker = FakePlaySegmentTracker()
        // Exactly the production shape: ONE closure per single-owner slot, each
        // dispatching to every consumer. A second assignment would silently clobber.
        harness.coordinator.onTrackStarted = { trackId in
            recorder.trackDidStart()
            tracker.beginTrack(trackRef: SegmentTrackerHarness.track(), profileId: 1)
            guard trackId > 0 else { return }
            counters.increment()
        }
        harness.coordinator.onPlayEvent = {
            recorder.record($0)
            tracker.flush(signal: $0)
        }
        harness.coordinator.onSeek = { tracker.noteSeek(from: $0, to: $1) }

        harness.coordinator.setQueue([PlayEventHarness.track("a", id: 1)], startingAt: 0)
        harness.coordinator.seek(to: 30)
        harness.coordinator.next()

        #expect(counters.count == 1)
        #expect(recorder.trackStartCount == 1)
        #expect(tracker.begunTracks.count == 1)
        #expect(recorder.signals.count == 1)
        #expect(tracker.signals.count == 1)
        #expect(tracker.seeks.count == 1)
        #expect(recorder.signals.map(\.reason) == tracker.signals.map(\.reason))
    }
}

@MainActor
final class TrackStartCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

// MARK: - The matrix

extension SegmentLifecycle {
    static let matrix: [SegmentLifecycle] = [
        SegmentLifecycle(
            name: "gapless natural advance",
            script: { harness in
                harness.begin()
                harness.listen(from: 0, to: 99)
                // Fires after the successor started, before `.natural` lands.
                harness.tracker.ingest(sample: PlayheadSample(time: 0.3, isPlaying: true))
                await harness.flush(.natural)
            },
            expected: SegmentExpectation(merges: 1, filled: [(0 ... 98, 1)])
        ),
        SegmentLifecycle(
            name: "karaoke mid-song reload",
            script: { harness in
                harness.begin()
                harness.listen(from: 0, to: 10)
                harness.tracker.ingest(sample: PlayheadSample(time: 10.7, isPlaying: true))
                harness.listen(from: 11.7, to: 20.7)
                await harness.flush(.jump)
            },
            expected: SegmentExpectation(merges: 1, filled: [(0 ... 20, 1)])
        ),
        SegmentLifecycle(
            name: "relaunch restore then resume",
            script: { harness in
                harness.listen(from: 0, to: 20)
                await harness.flush(.jump)
            },
            expected: SegmentExpectation(merges: 1, filled: [(0 ... 19, 1)])
        ),
        SegmentLifecycle(
            name: "repeat one, two full passes",
            script: { harness in
                for _ in 0 ..< 2 {
                    harness.begin()
                    harness.listen(from: 0, to: 99)
                    await harness.flush(.natural)
                }
            },
            expected: SegmentExpectation(merges: 2, filled: [(0 ... 99, 2)])
        ),
        SegmentLifecycle(
            name: "remove current, successor follows",
            script: { harness in
                harness.begin()
                harness.listen(from: 0, to: 30)
                await harness.flush(.jump)
            },
            expected: SegmentExpectation(merges: 1, filled: [(0 ... 29, 1)])
        ),
        SegmentLifecycle(
            name: "remove current, queue runs dry",
            script: { harness in
                harness.begin()
                harness.listen(from: 0, to: 30)
                await harness.flush(.stopped)
            },
            expected: SegmentExpectation(merges: 1, filled: [(0 ... 29, 1)])
        ),
        SegmentLifecycle(
            name: "setQueue replaces the queue mid-play",
            script: { harness in
                harness.begin()
                harness.listen(from: 0, to: 15)
                await harness.flush(.jump)
            },
            expected: SegmentExpectation(merges: 1, filled: [(0 ... 14, 1)])
        ),
        SegmentLifecycle(
            name: "context, manual, context",
            script: { harness in
                harness.begin()
                harness.listen(from: 0, to: 10)
                await harness.flush(.jump)
                // A manual-queue play never fires `onTrackStarted`; lazy-begin adopts it.
                harness.listen(from: 0, to: 5)
                await harness.flush(.jump)
                harness.begin()
                harness.listen(from: 0, to: 10)
                await harness.flush(.jump)
            },
            expected: SegmentExpectation(merges: 3, filled: [(0 ... 4, 3), (5 ... 9, 2)])
        ),
        SegmentLifecycle(
            name: "engine load failure, nothing played",
            script: { harness in
                harness.begin()
                await harness.flush(.jump)
            },
            expected: SegmentExpectation(merges: 0)
        ),
        SegmentLifecycle(
            name: "profile switch mid-track",
            script: { harness in
                harness.begin()
                harness.listen(from: 0, to: 20)
                await harness.flush(.profileSwitch)
                harness.tracker.rescope(to: 314)
                harness.listen(from: 0, to: 10)
                await harness.flush(.jump)
            },
            expected: SegmentExpectation(
                merges: 2,
                filled: [(0 ... 9, 2), (10 ... 19, 1)],
                profileIds: [SegmentTrackerHarness.profileId, 314]
            )
        ),
        SegmentLifecycle(
            name: "termination flush",
            script: { harness in
                harness.begin()
                harness.listen(from: 0, to: 20)
                harness.tracker.flush(signal: SegmentTrackerHarness.signal(.stopped))
                await harness.tracker.flushAndWait()
            },
            expected: SegmentExpectation(merges: 1, filled: [(0 ... 19, 1)])
        ),
    ]

    /// The full 100-bucket array a `filled` shorthand stands for.
    static func expand(_ filled: [(ClosedRange<Int>, UInt32)]) -> [UInt32] {
        var buckets = [UInt32](repeating: 0, count: PlaySegmentHeatRecord.bucketCount)
        for (range, count) in filled {
            for index in range {
                buckets[index] = count
            }
        }
        return buckets
    }
}
