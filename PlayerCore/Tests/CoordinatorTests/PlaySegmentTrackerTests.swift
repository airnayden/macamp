// PlaySegmentTrackerTests — the replay-heatmap capture rules, driven by hand.
//
// Every case feeds `ingest`/`noteSeek`/`flush` directly, so nothing depends on a
// timer, an engine, or wall-clock time. The fixture track is 100 seconds, so one
// second is exactly one bucket.
import Foundation
import Persistence
@testable import Services
import Testing

@MainActor
@Suite("PlaySegmentTrackerTests")
struct PlaySegmentTrackerTests {
    @Test("an uninterrupted listen fills every bucket once")
    func fullListenFillsEveryBucket() async throws {
        let harness = try SegmentTrackerHarness()
        harness.begin()
        harness.listen(from: 0, to: 99)

        await harness.flush(.natural)

        let merges = await harness.merges()
        let merge = try #require(merges.first)
        #expect(merges.count == 1)
        #expect(merge.deltas.allSatisfy { $0 == 1 })
        #expect(merge.profileId == SegmentTrackerHarness.profileId)
        #expect(merge.trackId == SegmentTrackerHarness.trackId)
        #expect(merge.identity.durationSeconds == SegmentTrackerHarness.duration)
    }

    @Test("a replayed section counts twice and the rest once — the most-replayed case")
    func backwardSeekDoublesTheReplayedSection() async throws {
        let harness = try SegmentTrackerHarness()
        harness.begin()
        harness.listen(from: 0, to: 40)
        harness.tracker.noteSeek(from: 40, to: 20)
        harness.listen(from: 21, to: 50)

        await harness.flush(.jump)

        let deltas = await harness.deltas()
        #expect(deltas[0 ... 19].allSatisfy { $0 == 1 })
        #expect(deltas[20 ... 39].allSatisfy { $0 == 2 })
        #expect(deltas[40 ... 49].allSatisfy { $0 == 1 })
        #expect(deltas[50 ... 99].allSatisfy { $0 == 0 })
    }

    @Test("a forward seek leaves the skipped stretch empty")
    func forwardSeekSkipsBuckets() async throws {
        let harness = try SegmentTrackerHarness()
        harness.begin()
        harness.listen(from: 0, to: 10)
        harness.tracker.noteSeek(from: 10, to: 80)
        harness.listen(from: 81, to: 90)

        await harness.flush(.jump)

        let deltas = await harness.deltas()
        #expect(deltas[0 ... 9].allSatisfy { $0 == 1 })
        #expect(deltas[10 ... 79].allSatisfy { $0 == 0 })
        #expect(deltas[80 ... 89].allSatisfy { $0 == 1 })
    }

    @Test("a pause splits the listen into two ranges but still commits one pass")
    func pauseKeepsOnePass() async throws {
        let harness = try SegmentTrackerHarness()
        harness.begin()
        harness.listen(from: 0, to: 30)
        harness.tracker.ingest(sample: PlayheadSample(time: 30, isPlaying: false))
        harness.listen(from: 30, to: 60)

        await harness.flush(.jump)

        let merges = await harness.merges()
        let deltas = await harness.deltas()
        #expect(merges.count == 1)
        #expect(deltas[0 ... 59].allSatisfy { $0 == 1 })
        #expect(deltas[60 ... 99].allSatisfy { $0 == 0 })
    }

    @Test("a non-library track writes nothing")
    func nonLibraryTrackWritesNothing() async throws {
        let harness = try SegmentTrackerHarness(track: SegmentTrackerHarness.track(id: nil))
        harness.begin()
        harness.listen(from: 0, to: 50)

        await harness.flush(.natural)

        #expect(await harness.merges().isEmpty)
    }

    @Test("an unknown-length track writes nothing")
    func unknownDurationWritesNothing() async throws {
        let harness = try SegmentTrackerHarness(track: SegmentTrackerHarness.track(duration: 0))
        harness.begin()
        harness.listen(from: 0, to: 50)

        await harness.flush(.natural)

        #expect(await harness.merges().isEmpty)
    }

    @Test("a flush with nothing listened writes nothing")
    func emptyFlushWritesNothing() async throws {
        let harness = try SegmentTrackerHarness()
        harness.begin()

        await harness.flush(.stopped)

        #expect(await harness.merges().isEmpty)
    }

    @Test("sub-second jitter from a karaoke swap does not split the listen")
    func jitterDoesNotSplitTheListen() async throws {
        let harness = try SegmentTrackerHarness()
        harness.begin()
        harness.listen(from: 0, to: 10)
        // The mid-song instrumental swap reloads and re-seeks, so the next reading
        // lands slightly behind where a clean 1 Hz cadence would have put it.
        harness.tracker.ingest(sample: PlayheadSample(time: 10.7, isPlaying: true))
        harness.tracker.ingest(sample: PlayheadSample(time: 11.7, isPlaying: true))
        harness.listen(from: 12.7, to: 20.7)

        await harness.flush(.jump)

        let deltas = await harness.deltas()
        #expect(deltas[0 ... 20].allSatisfy { $0 == 1 })
        #expect(deltas[21 ... 99].allSatisfy { $0 == 0 })
    }

    @Test("a tick at the gapless successor's position adds no bucket")
    func gaplessStrayTickAddsNothing() async throws {
        let harness = try SegmentTrackerHarness()
        harness.begin()
        harness.listen(from: 0, to: 99)
        // The successor is already playing when this tick fires, but the outgoing
        // track's `.natural` signal has not landed yet.
        harness.tracker.ingest(sample: PlayheadSample(time: 0.3, isPlaying: true))

        await harness.flush(.natural)

        let deltas = await harness.deltas()
        #expect(deltas[0 ... 98].allSatisfy { $0 == 1 })
        #expect(deltas[99] == 0)
    }

    @Test("a natural end completes the final bucket, a jump does not")
    func naturalEndExtendsOnlyWhenItReallyEnded() async throws {
        let ended = try SegmentTrackerHarness()
        ended.begin()
        ended.listen(from: 0, to: 99)
        await ended.flush(.natural)

        let cut = try SegmentTrackerHarness()
        cut.begin()
        cut.listen(from: 0, to: 99)
        await cut.flush(.userNext)

        #expect(await ended.deltas()[99] == 1)
        #expect(await cut.deltas()[99] == 0)
    }

    @Test("a listen ending exactly on a bucket edge leaves that bucket empty")
    func halfOpenBucketEdge() async throws {
        let harness = try SegmentTrackerHarness()
        harness.begin()
        harness.listen(from: 0, to: 40)

        await harness.flush(.jump)

        let deltas = await harness.deltas()
        #expect(deltas[0 ... 39].allSatisfy { $0 == 1 })
        #expect(deltas[40 ... 99].allSatisfy { $0 == 0 })
    }

    @Test("no sampler runs while playback is not active")
    func noTimerWhilePaused() async throws {
        let harness = try SegmentTrackerHarness()
        harness.begin()
        #expect(harness.tracker.isSampling == false)

        harness.playhead.time = 5
        harness.tracker.playbackStateDidChange(isPlaying: true)
        #expect(harness.tracker.isSampling)

        harness.listen(from: 6, to: 11)
        harness.playhead.time = 12
        harness.tracker.playbackStateDidChange(isPlaying: false)
        #expect(harness.tracker.isSampling == false)

        await harness.flush(.stopped)

        let deltas = await harness.deltas()
        #expect(deltas[5 ... 11].allSatisfy { $0 == 1 })
        #expect(deltas[0 ... 4].allSatisfy { $0 == 0 })
        #expect(deltas[12 ... 99].allSatisfy { $0 == 0 })
    }

    @Test("a restored session begins itself on the first playing sample")
    func lazyBeginAdoptsWhateverIsPlaying() async throws {
        let harness = try SegmentTrackerHarness()
        // No `beginTrack`: launch restore and every manual-queue play reach the
        // engine without an `onTrackStarted`.
        harness.listen(from: 0, to: 20)

        await harness.flush(.jump)

        let merge = try #require(await harness.merges().first)
        #expect(merge.trackId == SegmentTrackerHarness.trackId)
        #expect(merge.deltas[0 ... 19].allSatisfy { $0 == 1 })
    }

    @Test("a flush detaches the pass, so the next track cannot contaminate it")
    func flushDetachesBeforeTheNextTrack() async throws {
        let harness = try SegmentTrackerHarness()
        harness.begin()
        harness.listen(from: 0, to: 20)

        harness.tracker.flush(signal: SegmentTrackerHarness.signal(.userNext))
        // Arrives before the commit has necessarily run.
        harness.tracker.beginTrack(trackRef: SegmentTrackerHarness.track(id: 99), profileId: 7)
        harness.listen(from: 0, to: 5)
        await harness.tracker.flushAndWait()

        let merges = await harness.merges()
        #expect(merges.count == 1)
        #expect(merges.first?.trackId == SegmentTrackerHarness.trackId)
        #expect(await harness.deltas()[0 ... 19].allSatisfy { $0 == 1 })
        #expect(await harness.deltas()[20] == 0)
    }

    @Test("rescope re-points attribution at the incoming profile")
    func rescopeRepointsAttribution() async throws {
        let harness = try SegmentTrackerHarness()
        harness.tracker.rescope(to: 314)
        harness.listen(from: 0, to: 20)

        await harness.flush(.jump)

        #expect(await harness.merges().first?.profileId == 314)
    }
}
