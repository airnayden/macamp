// PlaybackCoordinatorTests — queue, navigation, shuffle, repeat, gapless
// pre-scheduling, availability skipping and snapshot/restore behaviour, all
// driven through the file-free ``SpyPlaybackEngine`` (no real audio).
import AudioEngine
import Foundation
import Persistence
@testable import Services
import Testing

@MainActor
@Suite(.serialized)
struct PlaybackCoordinatorTests {
    private func makeCoordinator(
        seed: UInt64 = 0
    ) -> (PlaybackCoordinator, SpyPlaybackEngine) {
        let engine = SpyPlaybackEngine()
        let coordinator = PlaybackCoordinator(
            engine: engine,
            randomNumberGenerator: SeededRandomNumberGenerator(seed: seed)
        )
        return (coordinator, engine)
    }

    // MARK: Queue setup + transport

    @Test("setQueue loads and plays the requested entry")
    func setQueuePlaysFirst() {
        let (coordinator, engine) = makeCoordinator()
        let trackA = TrackRef.fixture("a")
        let trackB = TrackRef.fixture("b")
        coordinator.setQueue([trackA, trackB], startingAt: 0)
        #expect(coordinator.current?.id == trackA.id)
        #expect(coordinator.state.playback == .playing)
        #expect(engine.loadedURLs == [trackA.url])
    }

    @Test("play / pause / toggle drive the engine transport")
    func transportToggles() {
        let (coordinator, _) = makeCoordinator()
        coordinator.setQueue([TrackRef.fixture("a")], startingAt: 0)
        #expect(coordinator.state.playback == .playing)
        coordinator.togglePlayPause()
        #expect(coordinator.state.playback == .paused)
        coordinator.togglePlayPause()
        #expect(coordinator.state.playback == .playing)
        coordinator.stop()
        #expect(coordinator.state.playback == .stopped)
    }

    // MARK: Queue editing

    @Test("append / insert / move / remove reshape the queue")
    func queueEditing() {
        let (coordinator, _) = makeCoordinator()
        let trackA = TrackRef.fixture("a")
        let trackB = TrackRef.fixture("b")
        let trackC = TrackRef.fixture("c")
        coordinator.setQueue([trackA, trackB], startingAt: nil)
        coordinator.append(trackC)
        #expect(coordinator.queue.map(\.id) == [trackA.id, trackB.id, trackC.id])
        let trackD = TrackRef.fixture("d")
        coordinator.insert(trackD, at: 1)
        #expect(coordinator.queue.map(\.id) == [trackA.id, trackD.id, trackB.id, trackC.id])
        coordinator.move(from: 0, to: 3)
        #expect(coordinator.queue.map(\.id) == [trackD.id, trackB.id, trackC.id, trackA.id])
        coordinator.remove(at: 1)
        #expect(coordinator.queue.map(\.id) == [trackD.id, trackC.id, trackA.id])
    }

    @Test("removing the current track advances to the next playable one")
    func removingCurrentAdvances() {
        let (coordinator, _) = makeCoordinator()
        let trackA = TrackRef.fixture("a")
        let trackB = TrackRef.fixture("b")
        let trackC = TrackRef.fixture("c")
        coordinator.setQueue([trackA, trackB, trackC], startingAt: 0)
        coordinator.remove(at: 0)
        #expect(coordinator.current?.id == trackB.id)
        #expect(coordinator.queue.map(\.id) == [trackB.id, trackC.id])
        #expect(coordinator.state.playback == .playing)
    }

    // MARK: Navigation + history

    @Test("next / previous walk the queue and previous is a no-op at the start")
    func nextPreviousWalk() {
        let (coordinator, engine) = makeCoordinator()
        let trackA = TrackRef.fixture("a")
        let trackB = TrackRef.fixture("b")
        let trackC = TrackRef.fixture("c")
        coordinator.setQueue([trackA, trackB, trackC], startingAt: 0)
        coordinator.next()
        #expect(coordinator.current?.id == trackB.id)
        coordinator.next()
        #expect(coordinator.current?.id == trackC.id)
        coordinator.previous()
        #expect(coordinator.current?.id == trackB.id)
        coordinator.previous()
        #expect(coordinator.current?.id == trackA.id)
        coordinator.previous()
        #expect(coordinator.current?.id == trackA.id)
        #expect(engine.loadedURLs == [trackA.url, trackB.url, trackC.url, trackB.url, trackA.url])
    }

    @Test("history is the tracks already played in the current cycle")
    func historyDerivation() {
        let (coordinator, _) = makeCoordinator()
        let trackA = TrackRef.fixture("a")
        let trackB = TrackRef.fixture("b")
        let trackC = TrackRef.fixture("c")
        coordinator.setQueue([trackA, trackB, trackC], startingAt: 0)
        #expect(coordinator.history.isEmpty)
        coordinator.next()
        #expect(coordinator.history.map(\.id) == [trackA.id])
        coordinator.next()
        #expect(coordinator.history.map(\.id) == [trackA.id, trackB.id])
    }
}

// MARK: - Repeat / availability / gapless / shuffle / snapshot

@MainActor
extension PlaybackCoordinatorTests {
    // MARK: Repeat policy

    @Test("repeat off stops at the end of the queue")
    func repeatOffStops() {
        let (coordinator, _) = makeCoordinator()
        let trackA = TrackRef.fixture("a")
        let trackB = TrackRef.fixture("b")
        coordinator.setQueue([trackA, trackB], startingAt: 0)
        coordinator.next()
        coordinator.next()
        #expect(coordinator.current?.id == trackB.id)
        #expect(coordinator.state.playback == .stopped)
    }

    @Test("repeat all wraps around to the first track")
    func repeatAllWraps() {
        let (coordinator, _) = makeCoordinator()
        let trackA = TrackRef.fixture("a")
        let trackB = TrackRef.fixture("b")
        coordinator.setQueue([trackA, trackB], startingAt: 0)
        coordinator.repeatMode = .all
        coordinator.next()
        coordinator.next()
        #expect(coordinator.current?.id == trackA.id)
        #expect(coordinator.state.playback == .playing)
    }

    @Test("repeat one replays the current track on auto-advance but manual next moves on")
    func repeatOneReplays() {
        let (coordinator, engine) = makeCoordinator()
        let trackA = TrackRef.fixture("a")
        let trackB = TrackRef.fixture("b")
        coordinator.setQueue([trackA, trackB], startingAt: 0)
        coordinator.repeatMode = .one
        coordinator.handleTrackDidFinish()
        #expect(coordinator.current?.id == trackA.id)
        #expect(engine.loadedURLs == [trackA.url, trackA.url])
        coordinator.next()
        #expect(coordinator.current?.id == trackB.id)
    }

    // MARK: Availability skipping

    @Test("next skips unavailable tracks to the next available one")
    func nextSkipsUnavailable() {
        let (coordinator, engine) = makeCoordinator()
        let trackA = TrackRef.fixture("a")
        let trackB = TrackRef.fixture("b", availability: .missing)
        let trackC = TrackRef.fixture("c")
        coordinator.setQueue([trackA, trackB, trackC], startingAt: 0)
        coordinator.next()
        #expect(coordinator.current?.id == trackC.id)
        #expect(engine.loadedURLs == [trackA.url, trackC.url])
    }

    @Test("an unavailable first entry is skipped when playback starts")
    func initialPlaySkipsUnavailable() {
        let (coordinator, engine) = makeCoordinator()
        let trackA = TrackRef.fixture("a", availability: .externalOffline)
        let trackB = TrackRef.fixture("b")
        coordinator.setQueue([trackA, trackB], startingAt: 0)
        #expect(coordinator.current?.id == trackB.id)
        #expect(engine.loadedURLs == [trackB.url])
    }

    // MARK: Gapless pre-scheduling

    @Test("the next available track is enqueued before the current one ends")
    func preschedulesNextBeforeEnd() {
        let (coordinator, engine) = makeCoordinator()
        let trackA = TrackRef.fixture("a")
        let trackB = TrackRef.fixture("b")
        let trackC = TrackRef.fixture("c")
        coordinator.setQueue([trackA, trackB, trackC], startingAt: 0)
        coordinator.prescheduleNextIfNeeded()
        #expect(coordinator.current?.id == trackA.id)
        #expect(engine.enqueuedURLs == [trackB.url])
    }

    @Test("pre-scheduling skips an unavailable successor")
    func preschedulesSkipUnavailable() {
        let (coordinator, engine) = makeCoordinator()
        let trackA = TrackRef.fixture("a")
        let trackB = TrackRef.fixture("b", availability: .missing)
        let trackC = TrackRef.fixture("c")
        coordinator.setQueue([trackA, trackB, trackC], startingAt: 0)
        coordinator.prescheduleNextIfNeeded()
        #expect(engine.enqueuedURLs == [trackC.url])
    }

    @Test("pre-scheduling the same successor twice enqueues it once")
    func preschedulesIdempotent() {
        let (coordinator, engine) = makeCoordinator()
        let trackA = TrackRef.fixture("a")
        let trackB = TrackRef.fixture("b")
        let trackC = TrackRef.fixture("c")
        coordinator.setQueue([trackA, trackB, trackC], startingAt: 0)
        coordinator.prescheduleNextIfNeeded()
        coordinator.prescheduleNextIfNeeded()
        #expect(engine.enqueuedURLs == [trackB.url])
        coordinator.next()
        coordinator.prescheduleNextIfNeeded()
        #expect(engine.enqueuedURLs == [trackB.url, trackC.url])
    }

    // MARK: Shuffle stability

    @Test("shuffle order is stable: it does not re-randomise mid-cycle")
    func shuffleIsStable() {
        let (coordinator, _) = makeCoordinator(seed: 42)
        let tracks = (0 ..< 6).map { TrackRef.fixture("t\($0)") }
        coordinator.setQueue(tracks, startingAt: nil)
        coordinator.shuffle = true
        let firstOrder = coordinator.order
        #expect(Set(firstOrder) == Set(tracks.map(\.id)))
        #expect(firstOrder.count == tracks.count)
        coordinator.next()
        coordinator.next()
        coordinator.next()
        #expect(coordinator.order == firstOrder)
    }

    @Test("a full shuffled cycle visits every track exactly once")
    func shuffleVisitsEachOnce() {
        let (coordinator, _) = makeCoordinator(seed: 7)
        let tracks = (0 ..< 5).map { TrackRef.fixture("t\($0)") }
        coordinator.setQueue(tracks, startingAt: nil)
        coordinator.shuffle = true
        let expectedOrder = coordinator.order
        var visited: [UUID] = []
        for _ in 0 ..< tracks.count {
            coordinator.next()
            if let current = coordinator.current {
                visited.append(current.id)
            }
        }
        #expect(visited == expectedOrder)
        #expect(Set(visited) == Set(tracks.map(\.id)))
    }

    @Test("toggling shuffle on pins the current track to the front")
    func shufflePinsCurrent() {
        let (coordinator, _) = makeCoordinator(seed: 3)
        let tracks = (0 ..< 6).map { TrackRef.fixture("t\($0)") }
        coordinator.setQueue(tracks, startingAt: 0)
        let current = coordinator.current
        coordinator.shuffle = true
        #expect(coordinator.order.first == current?.id)
        #expect(coordinator.current?.id == current?.id)
    }

    // MARK: Snapshot / restore

    @Test("snapshot then restore round-trips current track, position and queue")
    func snapshotRestoreRoundTrips() throws {
        let provider = FakeDecoderProvider(duration: 100)
        let engine = SpyPlaybackEngine(decoderProvider: provider)
        let coordinator = PlaybackCoordinator(engine: engine)
        let trackA = TrackRef.fixture("a")
        let trackB = TrackRef.fixture("b")
        let trackC = TrackRef.fixture("c")
        coordinator.setQueue([trackA, trackB, trackC], startingAt: 1)
        coordinator.seek(to: 12.5)
        let snap = coordinator.snapshot()

        let encoded = try JSONEncoder().encode(snap)
        let decoded = try JSONDecoder().decode(CoordinatorSnapshot.self, from: encoded)
        #expect(decoded == snap)

        let restoredEngine = SpyPlaybackEngine(decoderProvider: provider)
        let restored = PlaybackCoordinator(engine: restoredEngine)
        restored.restore(from: decoded)
        #expect(restored.current?.id == trackB.id)
        #expect(restored.queue.map(\.id) == [trackA.id, trackB.id, trackC.id])
        #expect(abs(restored.currentTime - 12.5) < 0.01)
    }

    // MARK: Observation

    @Test("stateDidChange fires on transport and queue changes")
    func stateDidChangeFires() {
        let (coordinator, _) = makeCoordinator()
        let recorder = StateRecorder()
        coordinator.stateDidChange = { recorder.record($0) }
        coordinator.setQueue([TrackRef.fixture("a")], startingAt: 0)
        coordinator.pause()
        #expect(!recorder.states.isEmpty)
        #expect(recorder.states.contains { $0.playback == .playing })
        #expect(recorder.states.last?.playback == .paused)
    }
}
