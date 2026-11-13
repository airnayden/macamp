import Foundation
import Services
import Testing
@testable import ViewModels

/// Todo 10 acceptance, part 2 (widened by todo 6): progress lands on exactly the leaf
/// it names — so a late sample cannot resurrect a retired row and a busy row cannot
/// touch its siblings — the display window stays bounded, and the derived queries a
/// pause/resume control reads still hold with several rows in flight.
@MainActor
struct DownloadQueueStoreProgressTests {
    // MARK: Progress semantics

    @Test func progressAppliesOnlyToActiveRows() {
        let store = DownloadQueueStore()
        let current = downloadQueueTestItem("a")
        let pending = downloadQueueTestItem("b")
        store.ingest(sequence: 0, snapshot: DownloadQueueSnapshot(
            activeItems: [current], pendingItems: [pending], isPaused: false
        ))

        store.ingestProgress(id: pending.id, state: .downloading(fraction: 0.5, speedBytesPerSec: nil, etaSeconds: nil))
        #expect(store.activeRows.map(\.fraction) == [nil])

        store.ingestProgress(id: current.id, state: .downloading(fraction: 0.5, speedBytesPerSec: nil, etaSeconds: nil))
        #expect(store.activeRows.map(\.fraction) == [0.5])
    }

    /// The point of the whole leaf design, stated as a value: one row's sample must
    /// leave its siblings' state alone. (That it also leaves their view BODIES alone is
    /// measured in `macOS/Tests/DownloadsRowInvalidationTests.swift` — a value test
    /// cannot see an invalidation cascade.)
    @Test func aSampleTouchesOnlyTheLeafItNames() {
        let store = DownloadQueueStore()
        let items = ["a", "b", "c"].map { downloadQueueTestItem($0) }
        store.ingest(sequence: 0, snapshot: DownloadQueueSnapshot(
            activeItems: items, pendingItems: [], isPaused: false
        ))

        let sample = DownloadState.downloading(fraction: 0.6, speedBytesPerSec: nil, etaSeconds: nil)
        store.ingestProgress(id: items[1].id, state: sample)

        #expect(store.activeRows.map(\.fraction) == [nil, 0.6, nil])
        #expect(store.activeRows.map(\.state) == [.queued, sample, .queued])
    }

    /// The anti-resurrection guard: a sample produced before a cancel and delivered
    /// after the snapshot that retired the row must change nothing. The row's leaf is
    /// dropped with it, so the sample has nowhere to land.
    @Test func lateProgressForARemovedRowIsIgnored() {
        let store = DownloadQueueStore()
        let retired = downloadQueueTestItem("a")
        let successor = downloadQueueTestItem("b")

        store.ingest(sequence: 0, snapshot: DownloadQueueSnapshot(
            activeItems: [retired], pendingItems: [successor], isPaused: false
        ))
        store.ingestProgress(id: retired.id, state: .downloading(fraction: 0.4, speedBytesPerSec: nil, etaSeconds: nil))
        #expect(store.activeRows.map(\.fraction) == [0.4])

        store.ingest(sequence: 1, snapshot: DownloadQueueSnapshot(
            activeItems: [successor], pendingItems: [], isPaused: false
        ))
        store.ingestProgress(id: retired.id, state: .downloading(fraction: 0.9, speedBytesPerSec: nil, etaSeconds: nil))

        #expect(store.activeRows.map(\.id) == [successor.id])
        #expect(store.activeRows.first?.state == .queued)
        #expect(store.count == 1)
        #expect(store.version == 2)
    }

    /// A row that leaves and comes back (queued again after a cancel) gets a FRESH leaf,
    /// so no stale fraction rides along — the enqueue id differs, which is what makes
    /// this true by construction.
    @Test func drainingTheQueueErasesEveryLeaf() {
        let store = DownloadQueueStore()
        let first = downloadQueueTestItem("a")
        store.ingest(sequence: 0, snapshot: DownloadQueueSnapshot(
            activeItems: [first], pendingItems: [], isPaused: false
        ))
        store.ingestProgress(id: first.id, state: .downloading(fraction: 0.8, speedBytesPerSec: nil, etaSeconds: nil))
        #expect(store.activeRows.map(\.fraction) == [0.8])

        store.ingest(sequence: 1, snapshot: DownloadQueueSnapshot(
            activeItems: [], pendingItems: [], isPaused: false
        ))
        #expect(store.activeRows.isEmpty)

        store.ingestProgress(id: first.id, state: .downloading(fraction: 0.9, speedBytesPerSec: nil, etaSeconds: nil))
        #expect(store.activeRows.isEmpty)
    }

    /// A snapshot that merely enriches a SURVIVING row carries that row's
    /// pre-enrichment state; it must not rewind the live bar.
    @Test func enrichmentSnapshotDoesNotRewindLiveState() {
        let store = DownloadQueueStore()
        var current = downloadQueueTestItem("a")
        store.ingest(sequence: 0, snapshot: DownloadQueueSnapshot(
            activeItems: [current], pendingItems: [], isPaused: false
        ))
        store.ingestProgress(id: current.id, state: .downloading(fraction: 0.6, speedBytesPerSec: nil, etaSeconds: nil))

        current.title = "Enriched"
        store.ingest(sequence: 1, snapshot: DownloadQueueSnapshot(
            activeItems: [current], pendingItems: [], isPaused: false
        ))

        #expect(store.activeRows.map(\.fraction) == [0.6])
        #expect(store.activeRows.first?.title == "Enriched")
    }

    @Test func sameStateSampleIsDropped() {
        let store = DownloadQueueStore()
        let current = downloadQueueTestItem("a")
        store.ingest(sequence: 0, snapshot: DownloadQueueSnapshot(
            activeItems: [current], pendingItems: [], isPaused: false
        ))

        let sample = DownloadState.downloading(fraction: 0.3, speedBytesPerSec: nil, etaSeconds: nil)
        store.ingestProgress(id: current.id, state: sample)
        store.ingestProgress(id: current.id, state: sample)

        #expect(store.activeRows.first?.state == sample)
        #expect(store.version == 1)
    }

    @Test func progressIgnoredWhenIdle() {
        let store = DownloadQueueStore()
        store.ingestProgress(id: UUID(), state: .postProcessing(fraction: nil))
        #expect(store.activeRows.isEmpty)
    }

    // MARK: Bounded display window

    @Test func pendingRowsAreCappedAtTheDisplayWindow() {
        let store = DownloadQueueStore()
        let limit = DownloadQueueStore.displayWindowLimit
        let pending = (0 ..< (limit + 25)).map { downloadQueueTestItem("v\($0)") }

        store.ingest(sequence: 0, snapshot: DownloadQueueSnapshot(
            activeItems: [downloadQueueTestItem("cur")], pendingItems: pending, isPaused: false
        ))

        #expect(store.pendingItems.count == limit)
        #expect(store.pendingItems.first?.id == pending.first?.id)
        #expect(store.pendingOverflow == 25)
        #expect(store.count == limit + 26)
    }

    @Test func overflowChangeAloneBumpsVersion() {
        let store = DownloadQueueStore()
        let limit = DownloadQueueStore.displayWindowLimit
        let pending = (0 ..< (limit + 2)).map { downloadQueueTestItem("v\($0)") }

        store.ingest(sequence: 0, snapshot: DownloadQueueSnapshot(
            activeItems: [], pendingItems: pending, isPaused: false
        ))
        #expect(store.pendingOverflow == 2)
        #expect(store.version == 1)

        store.ingest(sequence: 1, snapshot: DownloadQueueSnapshot(
            activeItems: [], pendingItems: Array(pending.dropLast()), isPaused: false
        ))
        #expect(store.pendingOverflow == 1)
        #expect(store.version == 2)
    }

    // MARK: Derived queries

    @Test func isWorkingReflectsInFlightAndPausedState() {
        let store = DownloadQueueStore()
        let current = downloadQueueTestItem("a")
        #expect(!store.isWorking)
        #expect(store.isEmpty)

        store.ingest(sequence: 0, snapshot: DownloadQueueSnapshot(
            activeItems: [current], pendingItems: [], isPaused: false
        ))
        #expect(store.isWorking)
        #expect(!store.isEmpty)

        store.ingest(sequence: 1, snapshot: DownloadQueueSnapshot(
            activeItems: [current], pendingItems: [], isPaused: true
        ))
        #expect(!store.isWorking)
    }

    /// Pause holds back NEW work only, so a paused queue whose transfers are still
    /// running is "not working" but definitely still active — the distinction the engine
    /// update's refusal depends on.
    @Test func aPausedQueueStillReportsItsActiveRows() {
        let store = DownloadQueueStore()
        store.ingest(sequence: 0, snapshot: DownloadQueueSnapshot(
            activeItems: [downloadQueueTestItem("a")],
            pendingItems: [downloadQueueTestItem("b")],
            isPaused: true
        ))

        #expect(!store.isWorking)
        #expect(store.activeRows.count == 1)
    }

    @Test func pendingWithoutAnActiveRowIsNotWorking() {
        let store = DownloadQueueStore()
        store.ingest(sequence: 0, snapshot: DownloadQueueSnapshot(
            activeItems: [], pendingItems: [downloadQueueTestItem("b")], isPaused: false
        ))
        #expect(!store.isWorking)
        #expect(store.count == 1)
    }
}
