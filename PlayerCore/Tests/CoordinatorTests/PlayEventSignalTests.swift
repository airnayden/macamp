// PlayEventSignalTests — one signal per transition, never two, never zero.
//
// Each test name is prefixed with the acceptance-criterion letter from
// `.omo/plans/stats-expansion.md` todo 2 so the matrix stays auditable.
import AudioEngine
import Foundation
@testable import Services
import Testing

@MainActor
@Suite(.serialized)
struct PlayEventSignalTests {
    @Test("(a) a natural end mid-queue emits one .natural whose elapsed is the full duration")
    func naturalEndMidQueue() throws {
        let harness = PlayEventHarness()
        harness.coordinator.setQueue([.fixture("a"), .fixture("b")], startingAt: 0)

        harness.coordinator.handleTrackDidFinish()

        let signal = try #require(harness.events.signals.first)
        #expect(harness.events.reasons == [.natural])
        #expect(signal.title == "a")
        #expect(signal.durationSeconds == PlayEventHarness.trackDuration)
        #expect(signal.elapsedSeconds == signal.durationSeconds)
    }

    @Test("(a) a natural end reports the finished track's duration, not the successor's playhead")
    func naturalEndIgnoresLivePlayhead() throws {
        let harness = PlayEventHarness()
        harness.coordinator.setQueue([.fixture("a"), .fixture("b")], startingAt: 0)
        harness.coordinator.seek(to: 3)

        harness.coordinator.handleTrackDidFinish()

        let signal = try #require(harness.events.signals.first)
        #expect(signal.elapsedSeconds == PlayEventHarness.trackDuration)
    }

    @Test("(b) a natural end on the LAST track emits one .natural and zero .stopped")
    func naturalEndOnLastTrack() {
        let harness = PlayEventHarness()
        harness.coordinator.setQueue([.fixture("only")], startingAt: 0)

        harness.coordinator.handleTrackDidFinish()

        #expect(harness.events.reasons == [.natural])
    }

    @Test("(c) next() at 20% emits one .userNext carrying the outgoing playhead")
    func userNextMidTrack() throws {
        let harness = PlayEventHarness()
        harness.coordinator.setQueue([.fixture("a"), .fixture("b")], startingAt: 0)
        harness.coordinator.seek(to: 20)

        harness.coordinator.next()

        let signal = try #require(harness.events.signals.first)
        #expect(harness.events.reasons == [.userNext])
        #expect(signal.title == "a")
        #expect(signal.elapsedSeconds == 20)
        #expect(signal.durationSeconds == PlayEventHarness.trackDuration)
    }

    @Test("(c) next() on the LAST track emits one .userNext and zero .stopped")
    func userNextOnLastTrack() {
        let harness = PlayEventHarness()
        harness.coordinator.setQueue([.fixture("only")], startingAt: 0)

        harness.coordinator.next()

        #expect(harness.events.reasons == [.userNext])
    }

    @Test("(d) play(at:) while another track plays emits one .jump for the outgoing track")
    func jumpToAnotherQueueEntry() throws {
        let harness = PlayEventHarness()
        harness.coordinator.setQueue([.fixture("a"), .fixture("b")], startingAt: 0)
        harness.coordinator.seek(to: 30)

        harness.coordinator.play(at: 1)

        let signal = try #require(harness.events.signals.first)
        #expect(harness.events.reasons == [.jump])
        #expect(signal.title == "a")
        #expect(signal.elapsedSeconds == 30)
    }

    @Test("(e) a mid-play setQueue replacement emits one .jump carrying the OUTGOING identity")
    func queueReplacementCapturesOutgoingBeforeMutation() throws {
        let harness = PlayEventHarness()
        let outgoing = PlayEventHarness.track("outgoing", id: 41)
        harness.coordinator.setQueue([outgoing], startingAt: 0)
        harness.coordinator.seek(to: 12)

        harness.coordinator.setQueue([PlayEventHarness.track("incoming", id: 99)], startingAt: 0)

        let signal = try #require(harness.events.signals.first)
        #expect(harness.events.reasons == [.jump])
        #expect(signal.outgoingTrackId == 41)
        #expect(signal.title == "outgoing")
        #expect(signal.artist == "artist-outgoing")
        #expect(signal.elapsedSeconds == 12)
    }

    @Test("(f) a user stop() emits one .stopped")
    func userStop() throws {
        let harness = PlayEventHarness()
        harness.coordinator.setQueue([.fixture("a"), .fixture("b")], startingAt: 0)
        harness.coordinator.seek(to: 44)

        harness.coordinator.stop()

        let signal = try #require(harness.events.signals.first)
        #expect(harness.events.reasons == [.stopped])
        #expect(signal.elapsedSeconds == 44)
    }

    @Test("(g) removeAll() mid-play emits one .stopped")
    func clearQueueMidPlay() throws {
        let harness = PlayEventHarness()
        harness.coordinator.setQueue([.fixture("a"), .fixture("b")], startingAt: 0)
        harness.coordinator.seek(to: 7)

        harness.coordinator.removeAll()

        let signal = try #require(harness.events.signals.first)
        #expect(harness.events.reasons == [.stopped])
        #expect(signal.title == "a")
        #expect(signal.elapsedSeconds == 7)
    }

    @Test("(h) restore(from:) fires no signal")
    func restoreIsSilent() {
        let harness = PlayEventHarness()
        let track = TrackRef.fixture("restored")

        harness.coordinator.restore(from: PlayEventHarness.snapshot(of: track, position: 12))

        #expect(harness.events.signals.isEmpty)
    }

    @Test("(l) seek(to:) fires onSeek once with (from, to) and emits zero play events")
    func seekIsNotATransition() {
        let harness = PlayEventHarness()
        harness.coordinator.setQueue([.fixture("a")], startingAt: 0)
        harness.coordinator.seek(to: 25)

        harness.coordinator.seek(to: 60)

        #expect(harness.seeks.seeks == [
            SeekRecord(from: 0, target: 25),
            SeekRecord(from: 25, target: 60),
        ])
        #expect(harness.events.signals.isEmpty)
    }

    @Test("(n) stop() then play(at:) a DIFFERENT track emits one .stopped and nothing more")
    func stopThenPlayAnotherTrack() throws {
        let harness = PlayEventHarness()
        harness.coordinator.setQueue([.fixture("a"), .fixture("b")], startingAt: 0)
        harness.coordinator.seek(to: 40)
        harness.coordinator.stop()

        harness.coordinator.play(at: 1)

        let signal = try #require(harness.events.signals.first)
        #expect(harness.events.reasons == [.stopped])
        #expect(signal.title == "a")
        #expect(signal.elapsedSeconds == 40)
        #expect(harness.engine.currentTime == 0)
    }

    @Test("(p) a no-op previous() at the head of the queue emits nothing")
    func noOpPreviousIsSilent() {
        let harness = PlayEventHarness()
        harness.coordinator.setQueue([.fixture("a"), .fixture("b")], startingAt: 0)
        harness.coordinator.seek(to: 5)

        harness.coordinator.previous()

        #expect(harness.events.signals.isEmpty)
        #expect(harness.coordinator.current?.title == "a")
    }

    @Test("(p) previous() from the second entry still emits one .userPrevious")
    func realPreviousEmits() {
        let harness = PlayEventHarness()
        harness.coordinator.setQueue([.fixture("a"), .fixture("b")], startingAt: 1)
        harness.coordinator.seek(to: 5)

        harness.coordinator.previous()

        #expect(harness.events.reasons == [.userPrevious])
    }

    @Test("(q) an explicit same-track restart emits one .jump stamped with the original begin time")
    func sameTrackRestart() throws {
        let harness = PlayEventHarness()
        harness.coordinator.setQueue([.fixture("a"), .fixture("b")], startingAt: 0)
        harness.coordinator.seek(to: 10)

        harness.coordinator.play(at: 0)

        let signal = try #require(harness.events.signals.first)
        #expect(harness.events.reasons == [.jump])
        #expect(signal.title == "a")
        #expect(signal.elapsedSeconds == 10)
        #expect(signal.startedAt == PlayEventHarness.epoch)
    }

    @Test("(u) a manual-queue play stamps its own begin time without onTrackStarted")
    func manualPlayCarriesBeginTime() throws {
        let harness = PlayEventHarness()
        harness.coordinator.setQueue([.fixture("context")], startingAt: 0)
        harness.coordinator.enqueueManual(.fixture("manual"))
        harness.coordinator.playManual(at: 0)
        harness.coordinator.seek(to: 5)

        harness.coordinator.stop()

        let manualStop = try #require(harness.events.signals.last)
        #expect(harness.events.reasons == [.jump, .stopped])
        #expect(manualStop.title == "manual")
        #expect(manualStop.startedAt == PlayEventHarness.epoch)
        #expect(manualStop.elapsedSeconds == 5)
    }

    @Test("(u) a restored-then-resumed play stamps the resume as its begin time")
    func restoreResumeCarriesBeginTime() throws {
        let harness = PlayEventHarness()
        let track = TrackRef.fixture("restored")
        harness.coordinator.restore(from: PlayEventHarness.snapshot(of: track, position: 12))

        harness.coordinator.play()
        harness.coordinator.stop()

        let signal = try #require(harness.events.signals.first)
        #expect(harness.events.reasons == [.stopped])
        #expect(signal.startedAt == PlayEventHarness.epoch)
        #expect(signal.elapsedSeconds == 12)
        #expect(signal.durationSeconds == PlayEventHarness.trackDuration)
    }

    @Test("flushForTermination emits the in-flight play once, and only once")
    func terminationFlush() throws {
        let harness = PlayEventHarness()
        harness.coordinator.setQueue([.fixture("a")], startingAt: 0)
        harness.coordinator.seek(to: 33)

        harness.coordinator.flushForTermination()
        harness.coordinator.flushForTermination()

        let signal = try #require(harness.events.signals.first)
        #expect(harness.events.reasons == [.stopped])
        #expect(signal.elapsedSeconds == 33)
    }

    @Test("flushForTermination with nothing playing emits nothing")
    func terminationFlushWhenIdle() {
        let harness = PlayEventHarness()

        harness.coordinator.flushForTermination()

        #expect(harness.events.signals.isEmpty)
    }
}

extension PlayEventHarness {
    static func snapshot(of track: TrackRef, position: TimeInterval) -> CoordinatorSnapshot {
        CoordinatorSnapshot(
            entries: [track],
            order: [track.id],
            currentID: track.id,
            shuffle: false,
            repeatMode: .off,
            position: position
        )
    }
}
