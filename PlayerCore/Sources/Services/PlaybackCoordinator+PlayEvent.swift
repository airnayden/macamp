// PlaybackCoordinator play-event instrumentation — the single emission choke point.
//
// Every way a play can end (natural end, next/previous, picking another track,
// replacing the queue, removing the current row, stop, clear-queue, quit) funnels
// through ONE helper, `emitOutgoingPlayEvent(reason:)`, guarded by a coordinator-
// owned `transitionConsumed` flag. That matters because the transport paths nest:
// `advanceForward` calls the public `stop()`, and `play(at:)` / `setQueue` /
// `playManual` bypass `advance` entirely by calling `activate` directly. Without
// the flag those overlaps double-fire; with it, the FIRST site to observe a
// transition owns it and every nested site is a no-op.
//
// The flag is reset in exactly two places — a SUCCESSFUL activation, and the
// completion of a terminal teardown — never in a `catch`. A load failure cascades
// (`activateManual` catch -> `advanceForward(automatic:)` -> `activate`) while the
// engine is still rendering the outgoing item, so resetting on failure would let
// the cascade emit a second event for a play that already ended.
//
// This file imports only AudioEngine + Foundation; it MUST NOT import AppKit or
// UIKit (PlayerCore portability invariant).
import AudioEngine
import Foundation

// MARK: - Public instrumentation surface

public extension PlaybackCoordinator {
    /// Emits the outgoing play event because the app is terminating.
    ///
    /// Shells call this at quit so the play in flight is not lost. It routes
    /// through the same consumed-flag helper as every other transition, so a quit
    /// that follows a stop (or a second call) emits nothing.
    func flushForTermination() {
        emitOutgoingPlayEvent(reason: .stopped)
    }

    /// Ends the outgoing profile's play, then tears the queue down for a switch.
    ///
    /// The profile-switch orchestration calls THIS rather than ``removeAll()``:
    /// `removeAll()` also reaches the emit helper, but stamps
    /// ``PlayEndReason/stopped`` for what was really a profile change. Emitting
    /// first claims the transition with the right reason and the nested
    /// `removeAll()` emit becomes a no-op, so the teardown is unchanged.
    func stopForProfileSwitch() {
        emitOutgoingPlayEvent(reason: .profileSwitch)
        removeAll()
    }

    /// Installs the source a restored session was playing from.
    ///
    /// The restore path calls this **unconditionally**, including with `nil`: a
    /// session restored without a persisted source must stamp
    /// ``PlayEventSourceSurface/unknown``, not inherit whatever was installed
    /// before. Unlike ``setQueue(_:startingAt:engagingKaraoke:source:)`` this does
    /// not publish through `playbackSourceDidChange` — the restorer owns that.
    func setRestoredSource(_ source: PlaybackSource?) {
        activeSource = source
    }
}

// MARK: - Emission

extension PlaybackCoordinator {
    /// Emits the outgoing play event exactly once per real transition.
    ///
    /// Reads the outgoing identity from ``current`` and the playhead from the
    /// engine BEFORE any caller mutates them, so the snapshot survives the queue
    /// surgery that follows.
    func emitOutgoingPlayEvent(reason: PlayEndReason) {
        guard !transitionConsumed, let track = current else { return }
        guard reason == .natural || engineHoldsLiveItem else { return }
        let duration = outgoingDurationSeconds
        let elapsed = reason == .natural ? duration : max(0, engine.currentTime)
        let signal = PlayEventSignal(
            outgoingTrackId: track.trackID,
            title: track.title,
            artist: track.artist,
            startedAt: currentBeganAt ?? (nowProvider() - elapsed),
            elapsedSeconds: elapsed,
            durationSeconds: duration,
            reason: reason,
            shuffle: plan.shuffle,
            sourceSurface: outgoingSourceSurface
        )
        transitionConsumed = true
        onPlayEvent?(signal)
    }

    /// Whether the engine still holds the outgoing item.
    ///
    /// Defence-in-depth for the stop-then-play edge: after ``stop()`` the engine
    /// zeroes its position but ``current`` still names the stopped track, so the
    /// `.jump` at activate-top would otherwise emit a phantom zero-length play.
    /// `.natural` deliberately bypasses this — it is raised by the engine's own
    /// end-of-audio callback (delivered through an async main-actor hop, by which
    /// point the transport may already read `.stopped`), and its elapsed value
    /// never depends on the live playhead.
    private var engineHoldsLiveItem: Bool {
        engine.state == .playing || engine.state == .paused
    }

    /// The outgoing item's length, preferring the value captured when it was
    /// loaded: under gapless the engine may already report the SUCCESSOR's.
    private var outgoingDurationSeconds: Double {
        if currentTrackDuration > 0 { return currentTrackDuration }
        if let known = current?.duration, known > 0 { return known }
        return max(0, engine.duration)
    }

    /// A manual-queue play carries no context source, so it stamps its own token;
    /// ``activeSource`` is left intact so the context survives the detour.
    private var outgoingSourceSurface: String {
        currentManualTrack == nil
            ? PlayEventSourceSurface.surface(for: activeSource)
            : PlayEventSourceSurface.manualQueue
    }
}

// MARK: - Play-window lifecycle

extension PlaybackCoordinator {
    /// Stamps the begin time the first time the loaded item actually plays.
    ///
    /// Idempotent, so a pause/resume keeps the ORIGINAL begin time. Driven both
    /// from the engine's state callback (restore-resume, load-while-paused) and
    /// directly from activation, so no path depends on `onTrackStarted`.
    func markPlaybackBegan() {
        guard currentBeganAt == nil else { return }
        currentBeganAt = nowProvider()
    }

    /// Completes a terminal teardown: nothing is playing, so the next transition
    /// starts from a clean slate. This is the ONLY reset point besides a
    /// successful activation.
    func finishTerminalTeardown() {
        transitionConsumed = false
        currentBeganAt = nil
        preLoadGeneration &+= 1
    }

    /// Records a freshly loaded item as an unstarted play.
    func beginPlaybackWindow() {
        currentBeganAt = nil
        currentTrackDuration = engine.duration
        transitionConsumed = false
    }
}

// MARK: - Queue replacement primitive

extension PlaybackCoordinator {
    /// The ONE queue-replacement primitive every `setQueue` overload funnels through.
    ///
    /// The ordering is load-bearing:
    /// 1. emit the outgoing event while the OLD ``activeSource`` is still installed,
    ///    so a replacement can never stamp the INCOMING surface onto the play it
    ///    interrupted, and while `plan` still knows the outgoing track (`setEntries`
    ///    clears `currentID`, which would otherwise lose the app's most common
    ///    "play these tracks" gesture entirely);
    /// 2. install the incoming source (`nil` for the source-less overload);
    /// 3. activate.
    func replaceQueue(_ tracks: [TrackRef], startingAt index: Int?, source: PlaybackSource?) {
        emitOutgoingPlayEvent(reason: .jump)
        activeSource = source
        plan.setEntries(tracks, using: &rng)
        currentManualTrack = nil
        lastScheduledNextID = nil
        guard let start = index, plan.entries.indices.contains(start) else {
            engine.stop()
            finishTerminalTeardown()
            publish()
            return
        }
        activate(requestedID: plan.entries[start].id, startPlaying: true)
    }

    /// Whether an advance in `direction` will actually change what is playing.
    ///
    /// A backward step at the head of the cycle returns early inside
    /// ``advanceBackward(automatic:)`` without touching the engine, so it is not a
    /// transition and must emit nothing at all. Forward always changes something
    /// when there is anything to change; the emit helper's own `current` guard
    /// covers the empty-everything case.
    func advanceWillChangePlayback(_ direction: PlaybackQueue.Direction) -> Bool {
        guard direction == .backward, currentManualTrack == nil else { return true }
        guard !plan.order.isEmpty else { return false }
        return plan.nextPlayableID(
            from: plan.currentID,
            direction: .backward,
            repeatMode: repeatModeValue
        ) != nil
    }
}
