import Foundation
import Separation
import Testing
@testable import ViewModels

/// Task 3 acceptance (a)/(b): the in-memory karaoke queue store maps a
/// ``KaraokeQueueSnapshot`` onto its observable fields, bumps ``version`` only on a
/// membership change (equality-guarded), and applies progress solely to the in-flight
/// item — monotonically, resetting to `0` when the current item changes.
@MainActor
struct KaraokeQueueStoreTests {
    // MARK: Ingest + version semantics (a)

    @Test func ingestMapsSnapshotFieldsAndBumpsVersionOnMembershipChange() {
        let store = KaraokeQueueStore()
        #expect(store.version == 0)

        store.ingest(snapshot: KaraokeQueueSnapshot(
            currentURL: url("a"),
            pendingURLs: [url("b"), url("c")],
            isPaused: false
        ))

        #expect(store.currentPath == canonical("a"))
        #expect(store.pendingPaths == [canonical("b"), canonical("c")])
        #expect(!store.isPaused)
        #expect(store.version == 1)
    }

    @Test func sameValueIngestDoesNotBumpVersion() {
        let store = KaraokeQueueStore()
        let snapshot = KaraokeQueueSnapshot(currentURL: url("a"), pendingURLs: [url("b")], isPaused: false)

        store.ingest(snapshot: snapshot)
        #expect(store.version == 1)

        store.ingest(snapshot: snapshot) // identical membership → equality guard
        #expect(store.version == 1)
    }

    @Test func pauseChangeAloneBumpsVersion() {
        let store = KaraokeQueueStore()
        store.ingest(snapshot: KaraokeQueueSnapshot(currentURL: url("a"), pendingURLs: [], isPaused: false))
        #expect(store.version == 1)

        store.ingest(snapshot: KaraokeQueueSnapshot(currentURL: url("a"), pendingURLs: [], isPaused: true))
        #expect(store.isPaused)
        #expect(store.version == 2)
    }

    @Test func pendingReorderBumpsVersion() {
        let store = KaraokeQueueStore()
        store.ingest(snapshot: KaraokeQueueSnapshot(
            currentURL: url("a"),
            pendingURLs: [url("b"), url("c")],
            isPaused: false
        ))
        #expect(store.version == 1)

        store.ingest(snapshot: KaraokeQueueSnapshot(
            currentURL: url("a"),
            pendingURLs: [url("c"), url("b")],
            isPaused: false
        ))
        #expect(store.pendingPaths == [canonical("c"), canonical("b")])
        #expect(store.version == 2)
    }

    // MARK: Progress semantics (b)

    @Test func progressAppliesOnlyToCurrentItemAndIsMonotone() {
        let store = KaraokeQueueStore()
        store.ingest(snapshot: KaraokeQueueSnapshot(currentURL: url("a"), pendingURLs: [url("b")], isPaused: false))

        store.ingestProgress(url: url("b"), fraction: 0.5) // not the in-flight item
        #expect(store.currentProgress == 0)

        store.ingestProgress(url: url("a"), fraction: 0.3)
        #expect(store.currentProgress == 0.3)

        store.ingestProgress(url: url("a"), fraction: 0.2) // lower → ignored
        #expect(store.currentProgress == 0.3)

        store.ingestProgress(url: url("a"), fraction: 0.8)
        #expect(store.currentProgress == 0.8)

        #expect(store.version == 1) // progress never bumps version
    }

    @Test func progressResetsToZeroWhenCurrentItemChanges() {
        let store = KaraokeQueueStore()
        store.ingest(snapshot: KaraokeQueueSnapshot(currentURL: url("a"), pendingURLs: [url("b")], isPaused: false))
        store.ingestProgress(url: url("a"), fraction: 0.6)
        #expect(store.currentProgress == 0.6)

        store.ingest(snapshot: KaraokeQueueSnapshot(currentURL: url("b"), pendingURLs: [], isPaused: false))
        #expect(store.currentProgress == 0)
    }

    @Test func progressClampsToUnitRange() {
        let store = KaraokeQueueStore()
        store.ingest(snapshot: KaraokeQueueSnapshot(currentURL: url("a"), pendingURLs: [], isPaused: false))

        store.ingestProgress(url: url("a"), fraction: 2.0)
        #expect(store.currentProgress == 1)
    }

    @Test func progressIgnoredWhenIdle() {
        let store = KaraokeQueueStore()
        store.ingestProgress(url: url("a"), fraction: 0.5)
        #expect(store.currentProgress == 0)
    }

    // MARK: Canonicalization matches the ready store

    @Test func lookupPathsAreCanonicalized() {
        let store = KaraokeQueueStore()
        let symlinked = URL(fileURLWithPath: "/tmp/song.flac") // /tmp → /private/tmp on macOS
        store.ingest(snapshot: KaraokeQueueSnapshot(currentURL: symlinked, pendingURLs: [], isPaused: false))
        #expect(store.currentPath == symlinked.resolvingSymlinksInPath().standardizedFileURL.path)
    }

    // MARK: isQueued + isWorking queries (todos E/F consume these)

    @Test func isQueuedMatchesCurrentAndPendingItems() {
        let store = KaraokeQueueStore()
        store.ingest(snapshot: KaraokeQueueSnapshot(
            currentURL: url("a"),
            pendingURLs: [url("b"), url("c")],
            isPaused: false
        ))

        #expect(store.isQueued(filePath: url("a").path)) // in flight
        #expect(store.isQueued(filePath: url("b").path)) // pending
        #expect(store.isQueued(filePath: url("c").path)) // pending
        #expect(!store.isQueued(filePath: url("d").path)) // absent from the queue
    }

    @Test func isQueuedCanonicalizesInputPath() {
        let store = KaraokeQueueStore()
        let symlinked = URL(fileURLWithPath: "/tmp/song.flac") // /tmp → /private/tmp on macOS
        store.ingest(snapshot: KaraokeQueueSnapshot(currentURL: symlinked, pendingURLs: [], isPaused: false))
        #expect(store.isQueued(filePath: "/tmp/song.flac")) // non-canonical spelling still matches
    }

    @Test func isWorkingReflectsCurrentAndPausedState() {
        let store = KaraokeQueueStore()
        #expect(!store.isWorking) // idle: nothing in flight

        store.ingest(snapshot: KaraokeQueueSnapshot(currentURL: url("a"), pendingURLs: [], isPaused: false))
        #expect(store.isWorking) // in flight + not paused

        store.ingest(snapshot: KaraokeQueueSnapshot(currentURL: url("a"), pendingURLs: [], isPaused: true))
        #expect(!store.isWorking) // in flight but paused
    }

    @Test func isWorkingFalseWhenPendingButNothingInFlight() {
        let store = KaraokeQueueStore()
        store.ingest(snapshot: KaraokeQueueSnapshot(currentURL: nil, pendingURLs: [url("b")], isPaused: false))
        #expect(!store.isWorking) // pending items, but no current item
    }
}

private func url(_ name: String) -> URL {
    URL(fileURLWithPath: "/m/\(name).flac")
}

private func canonical(_ name: String) -> String {
    url(name).resolvingSymlinksInPath().standardizedFileURL.path
}
