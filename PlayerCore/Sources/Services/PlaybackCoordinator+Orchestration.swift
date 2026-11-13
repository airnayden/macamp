// PlaybackCoordinator orchestration — the private navigation/activation core.
//
// Split out of `PlaybackCoordinator.swift` purely for the file-length budget; the
// members are module-`internal` (not `private`) so the public API extensions in
// the sibling file can drive them. This is the seam where the manual queue takes
// precedence over the context plan (see ``advanceForward(automatic:)``).
//
// This file imports only AudioEngine + Foundation; it MUST NOT import AppKit or
// UIKit (PlayerCore portability invariant).
import AudioEngine
import Foundation

extension PlaybackCoordinator {
    func advance(_ direction: PlaybackQueue.Direction, automatic: Bool) {
        if !automatic, advanceWillChangePlayback(direction) {
            emitOutgoingPlayEvent(reason: direction == .forward ? .userNext : .userPrevious)
        }
        if direction == .forward {
            advanceForward(automatic: automatic)
        } else {
            advanceBackward(automatic: automatic)
        }
    }

    /// Forward advance: replay (repeat-one), then the manual queue, then context.
    func advanceForward(automatic: Bool) {
        if automatic, repeatModeValue == .one, current != nil {
            replayCurrent()
            return
        }
        let keepPlaying = automatic || engine.state == .playing
        if let next = takeNextPlayableManual() {
            activateManual(next, startPlaying: keepPlaying)
            return
        }
        let hadManual = currentManualTrack != nil
        currentManualTrack = nil
        let target = plan.order.isEmpty
            ? nil
            : plan.nextPlayableID(from: plan.currentID, direction: .forward, repeatMode: repeatModeValue)
        guard let target else {
            if hadManual || !plan.order.isEmpty { stop() }
            return
        }
        activate(requestedID: target, startPlaying: keepPlaying)
    }

    /// Backward advance ignores the manual queue: from a manual track it returns
    /// to the context track, otherwise it steps back through the context order.
    func advanceBackward(automatic: Bool) {
        let keepPlaying = automatic || engine.state == .playing
        if currentManualTrack != nil {
            activate(requestedID: plan.currentID, startPlaying: keepPlaying)
            return
        }
        guard !plan.order.isEmpty,
              let target = plan.nextPlayableID(from: plan.currentID, direction: .backward, repeatMode: repeatModeValue)
        else { return }
        activate(requestedID: target, startPlaying: keepPlaying)
    }

    func replayCurrent() {
        if let manual = currentManualTrack {
            activateManual(manual, startPlaying: true)
        } else {
            activate(requestedID: plan.currentID, startPlaying: true)
        }
    }

    /// Pops the next playable manual track, discarding any unplayable ones.
    func takeNextPlayableManual() -> TrackRef? {
        while !manualQueueEntries.isEmpty {
            let candidate = manualQueueEntries.removeFirst()
            if candidate.isPlayable { return candidate }
        }
        return nil
    }

    /// Loads + (optionally) plays a manual-queue track. `plan.currentID` is left
    /// at the context track so playback resumes there once the manual queue drains.
    func activateManual(_ track: TrackRef, startPlaying: Bool) {
        emitOutgoingPlayEvent(reason: .jump)
        currentManualTrack = track
        lastScheduledNextID = nil
        let source = playbackSource(for: track)
        afterPreLoad(track) { coordinator in
            coordinator.loadManual(source: source, startPlaying: startPlaying)
        }
    }

    private func loadManual(source: DecoderSource, startPlaying: Bool) {
        do {
            try engine.load(source: source)
        } catch {
            currentManualTrack = nil
            advanceForward(automatic: true)
            return
        }
        activePlaybackSource = source
        beginPlaybackWindow()
        if startPlaying {
            engine.play()
            markPlaybackBegan()
        }
        refreshKaraokeResolutionIfActive()
        publish()
    }

    /// Loads and (optionally) plays the first playable ref at/after `requestedID`.
    /// If nothing is playable the engine is stopped and `current` cleared.
    func activate(requestedID: UUID?, startPlaying: Bool) {
        emitOutgoingPlayEvent(reason: .jump)
        currentManualTrack = nil
        guard let resolved = plan.firstPlayableID(preferring: requestedID), let track = plan.track(resolved) else {
            plan.currentID = nil
            engine.stop()
            finishTerminalTeardown()
            publish()
            return
        }
        plan.currentID = resolved
        lastScheduledNextID = nil
        let source = playbackSource(for: track)
        afterPreLoad(track) { coordinator in
            coordinator.loadActivated(track, source: source, startPlaying: startPlaying)
        }
    }

    private func loadActivated(_ track: TrackRef, source: DecoderSource, startPlaying: Bool) {
        do {
            try engine.load(source: source)
        } catch {
            engine.stop()
            finishTerminalTeardown()
            publish()
            return
        }
        activePlaybackSource = source
        beginPlaybackWindow()
        if startPlaying {
            engine.play()
            markPlaybackBegan()
            startListenTimer(for: track)
        }
        onTrackStarted?(track.trackID ?? 0)
        refreshKaraokeResolutionIfActive()
        publish()
    }

    /// Runs `load` now when no ``preLoadHook`` is installed, else awaits the hook
    /// first. The generation token is what makes the deferred form safe: a newer
    /// activation, a `stop()` or a queue clear bumps it while the continuation is
    /// still suspended, so that continuation loads nothing rather than
    /// resurrecting a track the user already moved off.
    private func afterPreLoad(
        _ track: TrackRef,
        _ load: @escaping @MainActor @Sendable (PlaybackCoordinator) -> Void
    ) {
        preLoadGeneration &+= 1
        guard let preLoadHook else {
            load(self)
            return
        }
        let generation = preLoadGeneration
        Task { @MainActor [weak self] in
            await preLoadHook(track)
            guard let self, preLoadGeneration == generation else { return }
            load(self)
        }
    }

    /// Clamps a seek target to the playing CUE SEGMENT's own bounds.
    ///
    /// A segment decoder reports region-relative time, so the engine's own
    /// `[0, duration]` already IS `[startFrame, endFrame)` — clamping here is what
    /// makes the pair reported through ``onSeek`` (and therefore the replay heatmap)
    /// describe where the playhead actually landed rather than where it was asked to
    /// go. Whole-file refs pass through untouched: the backends already bound an
    /// ordinary seek, and clamping them would change a value every existing consumer
    /// records.
    func segmentClampedSeekTime(_ time: TimeInterval) -> TimeInterval {
        guard current?.isCueSegment == true, engine.duration > 0 else { return time }
        return min(max(time, 0), engine.duration)
    }

    private func startListenTimer(for track: TrackRef) {
        listenTimerTask?.cancel()
        let trackID = track.trackID
        guard let trackID else { return }
        currentListenTrackID = trackID
        let threshold = listenThreshold
        listenTimerTask = Task { [weak self] in
            try? await Task.sleep(for: threshold)
            guard !Task.isCancelled else { return }
            self?.onTrackListened?(trackID)
        }
    }

    /// Cancels any pending listen timer and forgets the tracked id, so a later
    /// stop / queue clear (the profile switch todo 11 performs before flipping the
    /// active profile) cannot fire ``onTrackListened`` for a track that is no
    /// longer current — which would attribute the listen to the wrong profile.
    func cancelListenTimer() {
        listenTimerTask?.cancel()
        listenTimerTask = nil
        currentListenTrackID = nil
    }

    func applyQueueEdit() {
        lastScheduledNextID = nil
        refreshKaraokeResolutionIfActive()
        publish()
    }

    func publish() {
        state = CoordinatorState(
            current: current,
            queue: plan.entries,
            history: plan.history,
            shuffle: plan.shuffle,
            repeatMode: repeatModeValue,
            playback: engine.state,
            manualQueue: manualQueueEntries,
            karaokeActive: karaokeActive
        )
    }
}
