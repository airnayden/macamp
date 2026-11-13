import Foundation
import Separation
import Testing
@testable import ViewModels

/// Todo 4 (karaoke-queue-and-playback-restore): the Karaoke Queue header button derives
/// its three states — pause (working), resume (idle/paused with work), disabled (empty) —
/// purely from ``KaraokeQueueStore``. These cases lock the `isWorking` / `version`
/// behaviour each button state reads, prove every membership change bumps `version`
/// exactly once, and prove a repeated identical snapshot does NOT re-render (equality
/// guard). Split from `KaraokeQueueStoreTests` to stay under the type-body-length budget.
extension KaraokeQueueStoreTests {
    // MARK: paused-with-current → "resume" state, still enabled

    @Test func pausedWithCurrentIsResumableEnabledAndBumpsVersionOnce() {
        let store = KaraokeQueueStore()
        store.ingest(snapshot: bsSnap("a", ["b"], paused: false))
        #expect(store.isWorking) // in flight + not paused → button shows "pause"
        #expect(store.version == 1)

        store.ingest(snapshot: bsSnap("a", ["b"], paused: true))
        #expect(!store.isWorking) // paused → button shows "resume"
        #expect(store.currentPath == bsCanonical("a")) // still non-empty → button enabled
        #expect(store.version == 2) // isPaused changed → exactly one bump

        store.ingest(snapshot: bsSnap("a", ["b"], paused: true)) // identical → guarded
        #expect(store.version == 2)
    }

    // MARK: idle-with-pending → "resume" state, still enabled

    @Test func idleWithPendingIsResumableEnabledAndBumpsVersionOnce() {
        let store = KaraokeQueueStore()
        #expect(store.version == 0)

        store.ingest(snapshot: bsSnap(nil, ["b"], paused: false))
        #expect(!store.isWorking) // nothing in flight → button shows "resume"
        #expect(store.currentPath == nil)
        #expect(store.pendingPaths == [bsCanonical("b")]) // pending present → button enabled
        #expect(store.version == 1)

        store.ingest(snapshot: bsSnap(nil, ["b"], paused: false)) // identical → guarded
        #expect(store.version == 1)
    }

    // MARK: drained → disabled state

    @Test func drainedQueueIsIdleEmptyAndBumpsVersionOnce() {
        let store = KaraokeQueueStore()
        store.ingest(snapshot: bsSnap("a", [], paused: false))
        #expect(store.version == 1)

        store.ingest(snapshot: bsSnap(nil, [], paused: false))
        #expect(!store.isWorking) // idle → not working
        #expect(store.currentPath == nil)
        #expect(store.pendingPaths.isEmpty) // empty → button disabled
        #expect(store.version == 2)

        store.ingest(snapshot: bsSnap(nil, [], paused: false)) // identical drained → guarded
        #expect(store.version == 2)
    }

    // MARK: regression — per-track Stop refreshes the header button

    /// Regression for "the header button doesn't refresh after a per-track Stop". The stop
    /// (`stopCurrent()` → `pause()`) emits the exact snapshot sequence the store ingests:
    /// working → paused (in-flight still shown) → cancelled+requeued-front. ``isWorking``
    /// MUST fall to false at the PAUSED snapshot (the button flips working→resume) and stay
    /// false through the requeue; each membership change bumps ``version`` once.
    @Test func perTrackStopFlipsIsWorkingFalseAtPauseAndStaysFalse() {
        let store = KaraokeQueueStore()

        store.ingest(snapshot: bsSnap("a", ["b"], paused: false))
        #expect(store.isWorking) // A in flight, not paused → button shows "pause"
        #expect(store.version == 1)

        store.ingest(snapshot: bsSnap("a", ["b"], paused: true))
        #expect(!store.isWorking) // ← the refresh the regression missed
        #expect(store.version == 2)

        store.ingest(snapshot: bsSnap(nil, ["a", "b"], paused: true))
        #expect(!store.isWorking) // stays false (idle + paused)
        #expect(store.currentPath == nil)
        #expect(store.pendingPaths == [bsCanonical("a"), bsCanonical("b")]) // A requeued front
        #expect(store.version == 3)
    }
}

private func bsSnap(_ current: String?, _ pending: [String], paused: Bool) -> KaraokeQueueSnapshot {
    KaraokeQueueSnapshot(
        currentURL: current.map(bsURL),
        pendingURLs: pending.map(bsURL),
        isPaused: paused
    )
}

private func bsURL(_ name: String) -> URL {
    URL(fileURLWithPath: "/m/\(name).flac")
}

private func bsCanonical(_ name: String) -> String {
    bsURL(name).resolvingSymlinksInPath().standardizedFileURL.path
}
