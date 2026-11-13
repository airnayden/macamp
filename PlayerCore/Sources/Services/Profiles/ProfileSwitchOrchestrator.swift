// ProfileSwitchOrchestrator — the ordered, testable core of a profile switch.
//
// A profile switch has a strict effect order that must not be reshuffled:
//
//   0. capture the outgoing profile id from the orchestrator's stored active id,
//      cancel any pending playback-state save, and flush that outgoing profile's
//      playback state synchronously;
//   1. stop playback + clear the queue (cancels the listen timer so a pending
//      60 s "listened" credit can never be attributed to the profile we switch
//      TO — see `PlaybackCoordinator.cancelListenTimer`);
//   2. cancel any newly scheduled playback save again immediately after clear,
//      because `removeAll()` can schedule a fresh save as it zeroes transport
//      state;
//   3. capture the root snapshot, re-scope every profile-owned view model + the
//      library-roots store to the new profile, then retarget the folder watcher to
//      the new roots;
//   4. restart the scoped observations IMMEDIATELY (optimistic repopulation — the
//      UI shows the new profile's library without waiting on disk I/O);
//   5. and only THEN, off the switch's UI-critical path, trigger one scan +
//      availability reconcile of the new roots — SKIPPED entirely when the new
//      profile's root set is identical to the previous one (a 100k-track reconcile
//      is 100k file probes; the switch must feel instant, so we never block it on
//      a reconcile that cannot have changed anything);
//   6. finally, restore the incoming profile's playback snapshot after the full
//      switch sequence completes.
//
// The effects are injected as closures so the macOS composition root
// (`AppEnvironment.wireProfileSwitch`) supplies the REAL implementations while
// tests supply recording fakes — making the ordering (and the skip) verifiable at
// the PlayerCore seam without a macOS app target.
//
// `@MainActor` because a switch fires from `ProfileService.activate` (main-actor
// profile/session state) and every effect touches main-actor view models / stores.
//
// This file imports only Foundation; it MUST NOT import AppKit or UIKit
// (PlayerCore portability invariant).
import Foundation

/// Runs the ordered switch sequence for `profileId`. Fire this from the
/// `ProfileManaging.onActiveProfileChanged` seam, which itself only fires on a
/// REAL active-profile change — so re-selecting the same profile runs nothing.
@MainActor
public final class ProfileSwitchOrchestrator {
    private var activeProfileId: Int64
    private let cancelPendingPlaybackSave: () -> Void
    private let flushPlaybackState: (Int64) -> Void
    private let restorePlaybackState: (Int64) -> Void
    private let stopAndClearPlayback: () -> Void
    private let rescope: (Int64) -> Void
    private let restartObservations: () -> Void
    private let currentRootPaths: () -> Set<String>
    private let runScanAndReconcile: () -> Void

    /// - Parameters:
    ///   - activeProfileId: The profile currently considered active by the
    ///     orchestrator. Captured before each switch so we can flush the outgoing
    ///     profile synchronously.
    ///   - cancelPendingPlaybackSave: Cancels any scheduled playback-state save.
    ///   - flushPlaybackState: Persists the outgoing profile's playback snapshot
    ///     immediately before the switch mutates shared transport state.
    ///   - restorePlaybackState: Restores the incoming profile's playback snapshot
    ///     after the full switch sequence completes.
    ///   - stopAndClearPlayback: Stops playback and clears the queue (cancelling
    ///     the listen timer). Runs after the outgoing playback snapshot is flushed.
    ///   - rescope: Re-scopes every profile-owned view model + the roots store to
    ///     the new profile id, then retargets the folder watcher to the new roots.
    ///   - restartObservations: Restarts the scoped observations immediately for
    ///     optimistic repopulation.
    ///   - currentRootPaths: The active profile's current library-root path set —
    ///     read once before `rescope` (previous profile) and once after (new
    ///     profile) to decide whether the scan can be skipped.
    ///   - runScanAndReconcile: Triggers one (detached) scan + availability
    ///     reconcile of the new roots. Only called when the root set changed.
    public init(
        activeProfileId: Int64,
        cancelPendingPlaybackSave: @escaping () -> Void,
        flushPlaybackState: @escaping (Int64) -> Void,
        restorePlaybackState: @escaping (Int64) -> Void,
        stopAndClearPlayback: @escaping () -> Void,
        rescope: @escaping (Int64) -> Void,
        restartObservations: @escaping () -> Void,
        currentRootPaths: @escaping () -> Set<String>,
        runScanAndReconcile: @escaping () -> Void
    ) {
        self.activeProfileId = activeProfileId
        self.cancelPendingPlaybackSave = cancelPendingPlaybackSave
        self.flushPlaybackState = flushPlaybackState
        self.restorePlaybackState = restorePlaybackState
        self.stopAndClearPlayback = stopAndClearPlayback
        self.rescope = rescope
        self.restartObservations = restartObservations
        self.currentRootPaths = currentRootPaths
        self.runScanAndReconcile = runScanAndReconcile
    }

    /// Runs the ordered switch sequence for `profileId`.
    ///
    /// Exact order: cancel pending playback-state save, flush outgoing playback
    /// state, stop + clear playback, cancel
    /// any save that `removeAll()` may have scheduled, snapshot roots, rescope,
    /// restart observations, optionally reconcile new roots, then restore the
    /// incoming playback snapshot.
    public func handleSwitch(toProfileId profileId: Int64) {
        let outgoingProfileId = activeProfileId
        cancelPendingPlaybackSave()
        flushPlaybackState(outgoingProfileId)
        stopAndClearPlayback()
        cancelPendingPlaybackSave() // `removeAll()` can schedule a fresh save while clearing state.
        let previousRoots = currentRootPaths()
        rescope(profileId)
        activeProfileId = profileId
        restartObservations()
        let newRoots = currentRootPaths()
        if newRoots != previousRoots {
            runScanAndReconcile()
        }
        restorePlaybackState(profileId)
    }
}
