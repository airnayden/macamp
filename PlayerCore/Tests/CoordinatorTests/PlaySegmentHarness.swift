// Shared doubles for the replay-heatmap suites.
//
// The tracker's core is pure, so these tests never start a timer: they hand it
// `PlayheadSample`s directly and assert the deltas it commits.
import Foundation
import Persistence
@testable import Services

/// Records every merge instead of writing one.
actor SegmentHeatSpy: PlaySegmentHeatRepositoryProviding {
    struct Merge: Equatable {
        var profileId: Int64
        var trackId: Int64
        var identity: PlaySegmentIdentity
        var deltas: [UInt32]
        var updatedAt: TimeInterval
    }

    private(set) var merges: [Merge] = []

    func segmentHeat(profileId _: Int64, trackId _: Int64) async throws -> PlaySegmentHeatRecord? {
        nil
    }

    func mergeSegmentHeat(
        profileId: Int64,
        trackId: Int64,
        identity: PlaySegmentIdentity,
        deltas: [UInt32],
        updatedAt: TimeInterval
    ) async throws {
        merges.append(Merge(
            profileId: profileId,
            trackId: trackId,
            identity: identity,
            deltas: deltas,
            updatedAt: updatedAt
        ))
    }

    func allSegmentHeat(
        profileId _: Int64,
        after _: PageCursor<Int64>?,
        limit _: Int
    ) async throws -> Page<PlaySegmentHeatRecord, Int64> {
        Page(items: [], nextCursor: nil)
    }
}

/// The mutable playback readings the tracker samples.
@MainActor
final class PlayheadBox {
    var track: TrackRef?
    var time: TimeInterval = 0
    var profileId: Int64

    init(track: TrackRef? = nil, profileId: Int64) {
        self.track = track
        self.profileId = profileId
    }
}

/// A tracker over a spy heat repository and a hand-driven playhead.
///
/// The fixture track is 100 seconds long, so one second is exactly one bucket and
/// every bucket assertion reads as a percentage.
@MainActor
struct SegmentTrackerHarness {
    nonisolated static let duration: TimeInterval = 100
    nonisolated static let profileId: Int64 = 7
    nonisolated static let trackId: Int64 = 42
    nonisolated static let updatedAt: TimeInterval = 1_700_000_000

    let tracker: PlaySegmentTracker
    let heat = SegmentHeatSpy()
    let playhead: PlayheadBox

    init(track: TrackRef? = SegmentTrackerHarness.track()) throws {
        let database = try AppDatabase.makeEmpty()
        playhead = PlayheadBox(track: track, profileId: Self.profileId)
        let box = playhead
        tracker = PlaySegmentTracker(
            heat: heat,
            tracks: TrackRepository(database),
            playhead: PlaySegmentPlayhead(
                currentTrack: { box.track },
                currentTime: { box.time },
                activeProfileId: { box.profileId }
            ),
            now: { SegmentTrackerHarness.updatedAt }
        )
    }

    nonisolated static func track(
        id trackID: Int64? = SegmentTrackerHarness.trackId,
        duration: TimeInterval? = SegmentTrackerHarness.duration
    ) -> TrackRef {
        TrackRef(
            trackID: trackID,
            filePath: "/fixtures/heat.fake",
            title: "Heat",
            artist: "Heat Artist",
            duration: duration
        )
    }

    /// Starts the track the harness was built with.
    func begin() {
        guard let track = playhead.track else { return }
        tracker.beginTrack(trackRef: track, profileId: Self.profileId)
    }

    /// Feeds one playing sample per second from `start` through `end`, inclusive.
    func listen(from start: TimeInterval, to end: TimeInterval) {
        var time = start
        while time <= end + 0.0001 {
            tracker.ingest(sample: PlayheadSample(time: time, isPlaying: true))
            time += PlaySegmentTracker.sampleInterval
        }
    }

    /// Flushes and awaits the enqueued commit.
    func flush(_ reason: PlayEndReason) async {
        tracker.flush(signal: Self.signal(reason))
        await tracker.flushAndWait()
    }

    func merges() async -> [SegmentHeatSpy.Merge] {
        await heat.merges
    }

    /// The bucket deltas of the merge at `index`, or an all-zero array when there is
    /// no such merge — so a failing assertion names the bucket instead of trapping.
    func deltas(_ index: Int = 0) async -> [UInt32] {
        let merges = await heat.merges
        guard merges.indices.contains(index) else {
            return [UInt32](repeating: 0, count: PlaySegmentHeatRecord.bucketCount)
        }
        return merges[index].deltas
    }

    nonisolated static func signal(_ reason: PlayEndReason) -> PlayEventSignal {
        PlayEventSignal(
            outgoingTrackId: trackId,
            title: "Heat",
            artist: "Heat Artist",
            startedAt: updatedAt,
            elapsedSeconds: duration,
            durationSeconds: duration,
            reason: reason
        )
    }
}
