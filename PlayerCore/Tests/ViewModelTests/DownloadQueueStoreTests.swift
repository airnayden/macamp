import Foundation
import Services
import Testing
@testable import ViewModels

/// Builds a queue row for the download store suites.
///
/// Internal (not `private`) because the store's tests are split across files to stay
/// inside SwiftLint's `type_body_length` budget, and prefixed because the whole
/// `ViewModelTests` target shares one namespace.
func downloadQueueTestItem(_ videoID: String) -> DownloadItem {
    DownloadItem(
        canonicalVideoID: videoID,
        sourceURL: URL(string: "https://www.youtube.com/watch?v=\(videoID)")
            ?? URL(fileURLWithPath: videoID)
    )
}

/// Todo 10 acceptance, part 1: the reorder guard (sentinel `-1`, so the launch
/// snapshot at sequence `0` is applied) and the membership-versus-progress ``version``
/// discipline.
@MainActor
struct DownloadQueueStoreTests {
    // MARK: Reorder guard + the -1 sentinel

    /// The launch snapshot arrives at sequence `0`. A sentinel seeded at `0` would
    /// evaluate `0 > 0 == false` and silently discard it, leaving the queue empty until
    /// the next mutation — the exact `KaraokeReadyStore` bug this guards against.
    @Test func initialSnapshotAtSequenceZeroIsApplied() {
        let store = DownloadQueueStore()
        let current = downloadQueueTestItem("a")

        store.ingest(sequence: 0, snapshot: DownloadQueueSnapshot(
            activeItems: [current],
            pendingItems: [downloadQueueTestItem("b")],
            isPaused: false
        ))

        #expect(store.activeRows.map(\.id) == [current.id])
        #expect(store.pendingItems.count == 1)
        #expect(store.version == 1)
    }

    @Test func staleSequenceIsDroppedInFull() {
        let store = DownloadQueueStore()
        store.ingest(sequence: 5, snapshot: DownloadQueueSnapshot(
            activeItems: [downloadQueueTestItem("a")], pendingItems: [], isPaused: false
        ))
        #expect(store.version == 1)

        store.ingest(sequence: 4, snapshot: DownloadQueueSnapshot(
            activeItems: [], pendingItems: [downloadQueueTestItem("z")], isPaused: true
        ))

        #expect(store.activeRows.map(\.canonicalVideoID) == ["a"])
        #expect(store.pendingItems.isEmpty)
        #expect(!store.isPaused)
        #expect(store.version == 1)
    }

    @Test func equalSequenceIsDropped() {
        let store = DownloadQueueStore()
        store.ingest(sequence: 0, snapshot: DownloadQueueSnapshot(
            activeItems: [downloadQueueTestItem("a")], pendingItems: [], isPaused: false
        ))
        store.ingest(sequence: 0, snapshot: DownloadQueueSnapshot(
            activeItems: [], pendingItems: [], isPaused: true
        ))

        #expect(store.activeRows.map(\.canonicalVideoID) == ["a"])
        #expect(store.version == 1)
    }

    // MARK: Several rows in flight

    /// The driver runs up to `DownloadQueueLimits.maxConcurrentDownloads` transfers at
    /// once, so the active side is a LIST and its order is the driver's dequeue order.
    @Test func everyActiveItemGetsItsOwnLeafInDequeueOrder() {
        let store = DownloadQueueStore()
        let items = ["a", "b", "c"].map { downloadQueueTestItem($0) }

        store.ingest(sequence: 0, snapshot: DownloadQueueSnapshot(
            activeItems: items, pendingItems: [downloadQueueTestItem("d")], isPaused: false
        ))

        #expect(store.activeRows.map(\.canonicalVideoID) == ["a", "b", "c"])
        #expect(store.count == 4)
        #expect(store.isWorking)
    }

    /// A reordered active list is a membership change, and the leaves travel with their
    /// rows rather than being rebuilt — a bar mid-transfer must not restart because the
    /// driver's dequeue order shifted.
    @Test func reorderingTheActiveListKeepsEachRowsLeaf() {
        let store = DownloadQueueStore()
        let first = downloadQueueTestItem("a")
        let second = downloadQueueTestItem("b")
        store.ingest(sequence: 0, snapshot: DownloadQueueSnapshot(
            activeItems: [first, second], pendingItems: [], isPaused: false
        ))
        let leaves = store.activeRows

        store.ingest(sequence: 1, snapshot: DownloadQueueSnapshot(
            activeItems: [second, first], pendingItems: [], isPaused: false
        ))

        #expect(store.activeRows[0] === leaves[1])
        #expect(store.activeRows[1] === leaves[0])
        #expect(store.version == 2)
    }

    // MARK: Membership vs progress version discipline

    @Test func addingAndRemovingRowsBumpsVersion() {
        let store = DownloadQueueStore()
        let first = downloadQueueTestItem("a")
        let second = downloadQueueTestItem("b")

        store.ingest(sequence: 0, snapshot: DownloadQueueSnapshot(
            activeItems: [first], pendingItems: [second], isPaused: false
        ))
        #expect(store.version == 1)

        store.ingest(sequence: 1, snapshot: DownloadQueueSnapshot(
            activeItems: [first], pendingItems: [], isPaused: false
        ))
        #expect(store.pendingItems.isEmpty)
        #expect(store.version == 2)
    }

    @Test func progressTickNeverBumpsVersion() {
        let store = DownloadQueueStore()
        let current = downloadQueueTestItem("a")
        store.ingest(sequence: 0, snapshot: DownloadQueueSnapshot(
            activeItems: [current], pendingItems: [], isPaused: false
        ))
        #expect(store.version == 1)

        store.ingestProgress(id: current.id, state: .downloading(fraction: 0.2, speedBytesPerSec: nil, etaSeconds: nil))
        store.ingestProgress(id: current.id, state: .downloading(fraction: 0.7, speedBytesPerSec: 1024, etaSeconds: 3))
        store.ingestProgress(id: current.id, state: .postProcessing(fraction: nil))

        #expect(store.activeRows.first?.state == .postProcessing(fraction: nil))
        #expect(store.version == 1)
    }

    @Test func sameMembershipDoesNotBumpVersion() {
        let store = DownloadQueueStore()
        let snapshot = DownloadQueueSnapshot(
            activeItems: [downloadQueueTestItem("a")],
            pendingItems: [downloadQueueTestItem("b")],
            isPaused: false
        )

        store.ingest(sequence: 0, snapshot: snapshot)
        #expect(store.version == 1)

        store.ingest(sequence: 1, snapshot: snapshot)
        #expect(store.version == 1)
    }

    @Test func pauseChangeAloneBumpsVersion() {
        let store = DownloadQueueStore()
        let current = downloadQueueTestItem("a")
        store.ingest(sequence: 0, snapshot: DownloadQueueSnapshot(
            activeItems: [current], pendingItems: [], isPaused: false
        ))
        store.ingest(sequence: 1, snapshot: DownloadQueueSnapshot(
            activeItems: [current], pendingItems: [], isPaused: true
        ))

        #expect(store.isPaused)
        #expect(store.version == 2)
    }

    @Test func pendingReorderBumpsVersion() {
        let store = DownloadQueueStore()
        let first = downloadQueueTestItem("b")
        let second = downloadQueueTestItem("c")
        store.ingest(sequence: 0, snapshot: DownloadQueueSnapshot(
            activeItems: [], pendingItems: [first, second], isPaused: false
        ))
        store.ingest(sequence: 1, snapshot: DownloadQueueSnapshot(
            activeItems: [], pendingItems: [second, first], isPaused: false
        ))

        #expect(store.pendingItems.map(\.id) == [second.id, first.id])
        #expect(store.version == 2)
    }

    /// The metadata prefetch republishes the same rows with a title filled in. The row
    /// must update so the title renders, but membership did not change — so a consumer
    /// that only re-lays-out on ``version`` must not churn, and the SAME leaf instance
    /// must survive so the view holding it keeps its identity.
    @Test func metadataEnrichmentRefreshesTheLeafWithoutBumpingVersion() throws {
        let store = DownloadQueueStore()
        var current = downloadQueueTestItem("a")
        store.ingest(sequence: 0, snapshot: DownloadQueueSnapshot(
            activeItems: [current], pendingItems: [], isPaused: false
        ))
        let leaf = try #require(store.activeRows.first)
        #expect(leaf.title == "a")
        #expect(leaf.uploader == nil)

        current.title = "Never Gonna Give You Up"
        current.uploader = "Rick Astley"
        store.ingest(sequence: 1, snapshot: DownloadQueueSnapshot(
            activeItems: [current], pendingItems: [], isPaused: false
        ))

        #expect(store.activeRows.first === leaf)
        #expect(leaf.title == "Never Gonna Give You Up")
        #expect(leaf.uploader == "Rick Astley")
        #expect(store.version == 1)
    }
}
