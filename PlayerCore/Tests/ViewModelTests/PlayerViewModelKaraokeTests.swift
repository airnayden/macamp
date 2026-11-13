import Artwork
import Foundation
import Observation
import Separation
import Services
import Testing
@testable import ViewModels

@MainActor
struct PlayerViewModelKaraokeTests {
    private func makeTrack() -> TrackRef {
        TrackRef(filePath: "/music/one.flac", title: "One", artist: "Artist", duration: 100)
    }

    @Test func karaokeButtonStateDerivationTable() {
        // (off ⇒ hidden) — the Settings gate wins over every other input.
        #expect(
            PlayerViewModel.deriveKaraokeButtonState(
                settingEnabled: false,
                availability: .available,
                coordinatorActive: false,
                preparation: .cached
            ) == .hidden
        )
        // (on + separator unavailable ⇒ disabled(reason)).
        #expect(
            PlayerViewModel.deriveKaraokeButtonState(
                settingEnabled: true,
                availability: .unavailable(reason: .modelNotBundled),
                coordinatorActive: false,
                preparation: .notPrepared
            ) == .disabled(reason: .modelNotBundled)
        )
        // (on + uncached + prewarm 0.4 ⇒ preparing(0.4)).
        #expect(
            PlayerViewModel.deriveKaraokeButtonState(
                settingEnabled: true,
                availability: .available,
                coordinatorActive: false,
                preparation: .preparing(0.4)
            ) == .preparing(0.4)
        )
        // (on + cached ⇒ ready).
        #expect(
            PlayerViewModel.deriveKaraokeButtonState(
                settingEnabled: true,
                availability: .available,
                coordinatorActive: false,
                preparation: .cached
            ) == .ready
        )
        // (toggled / coordinator applied ⇒ active) — outranks ready/preparing.
        #expect(
            PlayerViewModel.deriveKaraokeButtonState(
                settingEnabled: true,
                availability: .available,
                coordinatorActive: true,
                preparation: .cached
            ) == .active
        )
    }

    @Test func karaokeButtonStateDerivesRenderableAndUnavailableCached() {
        // (on + available + notPrepared ⇒ renderable) — no cached instrumental; a press renders on demand.
        #expect(
            PlayerViewModel.deriveKaraokeButtonState(
                settingEnabled: true,
                availability: .available,
                coordinatorActive: false,
                preparation: .notPrepared
            ) == .renderable
        )
        // (on + separator unavailable + cached ⇒ disabled) — unavailability outranks a cached render.
        #expect(
            PlayerViewModel.deriveKaraokeButtonState(
                settingEnabled: true,
                availability: .unavailable(reason: .modelNotBundled),
                coordinatorActive: false,
                preparation: .cached
            ) == .disabled(reason: .modelNotBundled)
        )
    }

    @Test func toggleKaraokeForwardsToCoordinatorExactlyOncePerCall() {
        let coordinator = KaraokeSpyCoordinator()
        let model = PlayerViewModel(coordinator: coordinator, artworkProvider: FakeArtworkProvider())

        model.toggleKaraoke()
        #expect(coordinator.toggleKaraokeCallCount == 1)
        // Forwarded via toggleKaraoke() alone — no second path through setKaraokeActive.
        #expect(coordinator.setKaraokeActiveCalls.isEmpty)

        model.toggleKaraoke()
        #expect(coordinator.toggleKaraokeCallCount == 2)
    }

    @Test func liveInputsDriveButtonStateAndScopedProgress() {
        let coordinator = KaraokeSpyCoordinator()
        let track = makeTrack()
        let model = PlayerViewModel(coordinator: coordinator, artworkProvider: FakeArtworkProvider())

        #expect(model.karaokeButtonState == .hidden)

        model.setKaraokeAvailability(.available)
        model.setKaraokeSettingEnabled(true)
        // No cached instrumental yet ⇒ renderable (a press renders on demand).
        #expect(model.karaokeButtonState == .renderable)

        coordinator.emit(CoordinatorState(current: track))
        #expect(model.karaokeButtonState == .renderable)

        model.ingestKaraokePrewarmProgress(KaraokePrewarmProgress(url: track.url, fraction: 0.4))
        #expect(model.karaokeButtonState == .preparing(0.4))
        #expect(model.karaokePreparationProgress == 0.4)

        // Readiness now comes from the ready store, not a fraction-≥-1 heuristic.
        model.setCurrentTrackKaraokeReady(true)
        #expect(model.karaokeButtonState == .ready)
        #expect(model.karaokePreparationProgress == nil)

        // Upcoming-track progress never moves the current button.
        model.ingestKaraokePrewarmProgress(
            KaraokePrewarmProgress(url: URL(fileURLWithPath: "/music/two.flac"), fraction: 0.2)
        )
        #expect(model.karaokeButtonState == .ready)

        model.setKaraokeAvailability(.unavailable(reason: .modelLoadFailed))
        #expect(model.karaokeButtonState == .disabled(reason: .modelLoadFailed))

        model.setKaraokeAvailability(.available)
        coordinator.emit(CoordinatorState(current: track, karaokeActive: true))
        #expect(model.karaokeButtonState == .active)
    }

    @Test func requestKaraokeRenderFiresSeamWithCurrentTrackAndNoOpsWhenAbsent() {
        let coordinator = KaraokeSpyCoordinator()
        let track = makeTrack()
        let model = PlayerViewModel(coordinator: coordinator, artworkProvider: FakeArtworkProvider())

        var requested: [TrackRef] = []
        model.onRenderRequested = { requested.append($0) }

        // No current track ⇒ no-op.
        model.requestKaraokeRender()
        #expect(requested.isEmpty)

        // With a current track ⇒ fires once with that exact track.
        coordinator.emit(CoordinatorState(current: track))
        model.requestKaraokeRender()
        #expect(requested.count == 1)
        #expect(requested.first?.id == track.id)
    }

    @Test func redundantReadySetSkipsObservableRecompute() {
        let coordinator = KaraokeSpyCoordinator()
        let track = makeTrack()
        let model = PlayerViewModel(coordinator: coordinator, artworkProvider: FakeArtworkProvider())
        model.setKaraokeAvailability(.available)
        model.setKaraokeSettingEnabled(true)
        coordinator.emit(CoordinatorState(current: track))
        model.setCurrentTrackKaraokeReady(true)
        #expect(model.karaokeButtonState == .ready)

        // Positive control: a real change invalidates the tracked observable read.
        let changed = ObservationRecorder()
        withObservationTracking {
            _ = model.karaokeButtonState
        } onChange: {
            changed.didChange = true
        }
        model.setCurrentTrackKaraokeReady(false)
        #expect(model.karaokeButtonState == .renderable)
        #expect(changed.didChange)

        // Equality guard: a redundant set neither recomputes nor writes observable state.
        let unchanged = ObservationRecorder()
        withObservationTracking {
            _ = model.karaokeButtonState
        } onChange: {
            unchanged.didChange = true
        }
        model.setCurrentTrackKaraokeReady(false)
        #expect(unchanged.didChange == false)
    }
}

/// Captures whether a tracked `@Observable` read was invalidated. A reference type
/// so the `@Sendable` `onChange` closure records into shared state — a captured
/// local `var` is illegal from a `@Sendable` closure.
private final class ObservationRecorder: @unchecked Sendable {
    var didChange = false
}

@MainActor
final class KaraokeSpyCoordinator: PlaybackCoordinating {
    private(set) var toggleKaraokeCallCount = 0
    private(set) var setKaraokeActiveCalls: [Bool] = []

    var state = CoordinatorState()
    var stateDidChange: ((CoordinatorState) -> Void)?
    var current: TrackRef?
    var queue: [TrackRef] = []
    var history: [TrackRef] = []
    var shuffle = false
    var repeatMode: RepeatMode = .off
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var volume: Float = 1.0
    var balance: Float = 0
    var manualQueue: [TrackRef] = []
    var karaokeActive = false

    /// Publishes `newState` through the same observable path the real coordinator
    /// uses, so the bound view model applies it.
    func emit(_ newState: CoordinatorState) {
        state = newState
        current = newState.current
        stateDidChange?(newState)
    }

    func setVolume(_: Float) {}
    func setBalance(_: Float) {}

    func setKaraokeActive(_ active: Bool) {
        setKaraokeActiveCalls.append(active)
        karaokeActive = active
    }

    func toggleKaraoke() {
        toggleKaraokeCallCount += 1
    }

    func play() {}
    func pause() {}
    func togglePlayPause() {}
    func stop() {}
    func next() {}
    func previous() {}
    func seek(to _: TimeInterval) {}
    func play(at _: Int) {}
    func setQueue(_: [TrackRef], startingAt _: Int?) {}
    func setQueue(_: [TrackRef], startingAt _: Int, engagingKaraoke _: Bool, source _: PlaybackSource?) {}
    func append(_: TrackRef) {}
    func append(contentsOf _: [TrackRef]) {}
    func insert(_: TrackRef, at _: Int) {}
    func remove(at _: Int) {}
    func move(from _: Int, to _: Int) {}
    func removeAll() {}
    func reorderQueue(_: [TrackRef]) {}
    func enqueueManual(_: TrackRef) {}
    func enqueueManual(contentsOf _: [TrackRef]) {}
    func playNextManual(contentsOf _: [TrackRef]) {}
    func removeManual(at _: Int) {}
    func moveManual(from _: Int, to _: Int) {}
    func playManual(at _: Int) {}
    func clearManualQueue() {}
    func prescheduleNextIfNeeded() {}
    func handleTrackDidFinish() {}

    func snapshot() -> CoordinatorSnapshot {
        CoordinatorSnapshot(entries: [], order: [], currentID: nil, shuffle: false, repeatMode: .off, position: 0)
    }

    func restore(from _: CoordinatorSnapshot) {}
}
