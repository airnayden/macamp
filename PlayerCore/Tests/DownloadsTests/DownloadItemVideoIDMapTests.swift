// The UUID→videoID correlation table, tested for the one property that is easy to get
// wrong: ``DownloadItemVideoIDMap/ingest(_:)`` ACCUMULATES, it does not mirror.
//
// A map rebuilt from each snapshot would read perfectly in every ordinary test and then
// lose exactly the entry that matters in production. `settle(_:)` publishes the terminal
// `onItemProgress` BEFORE the post-removal snapshot today, so a mirroring map would
// happen to work — until the driver's internal ordering changed, at which point the row
// would already be gone from the snapshot by the time its terminal state arrived and the
// handler would resolve nothing. The accumulate tests below pin the behaviour so the map
// never depends on that ordering.
//
// Prefixed `ChatVideoIDMap…` because the whole `DownloadsTests` target shares one
// namespace.
import Foundation
import Services
import Testing

/// Fixed ids the suite correlates, kept out of the tests so a typo cannot make a
/// "resolves to the wrong video" assertion pass by accident.
enum ChatVideoIDMapFixture {
    static let first = "dQw4w9WgXcQ"
    static let second = "9bZkp7q19f0"
    static let third = "kJQP7kiw5Fk"

    static func item(_ videoID: String) -> DownloadItem {
        DownloadItem(
            canonicalVideoID: videoID,
            sourceURL: URL(fileURLWithPath: "/tmp/macamp-downloads").appendingPathComponent(videoID)
        )
    }

    static func snapshot(active: [DownloadItem] = [], pending: [DownloadItem] = []) -> DownloadQueueSnapshot {
        DownloadQueueSnapshot(activeItems: active, pendingItems: pending, isPaused: false)
    }
}

@MainActor
@Suite("Download item video id map")
struct DownloadItemVideoIDMapTests {
    @Test("an empty map resolves nothing and counts nothing")
    func emptyMapResolvesNothing() {
        let map = DownloadItemVideoIDMap()

        #expect(map.count == 0)
        #expect(map.videoID(for: UUID()) == nil)
    }

    /// Both halves of a snapshot are correlated: a row that is still pending will become
    /// active later and must already resolve if it is cancelled from the pending list.
    @Test("ingest correlates both the active and the pending halves of a snapshot")
    func ingestReadsBothHalves() {
        let map = DownloadItemVideoIDMap()
        let active = ChatVideoIDMapFixture.item(ChatVideoIDMapFixture.first)
        let pending = ChatVideoIDMapFixture.item(ChatVideoIDMapFixture.second)

        map.ingest(ChatVideoIDMapFixture.snapshot(active: [active], pending: [pending]))

        #expect(map.videoID(for: active.id) == ChatVideoIDMapFixture.first)
        #expect(map.videoID(for: pending.id) == ChatVideoIDMapFixture.second)
        #expect(map.count == 2)
    }

    /// The accumulate lock. A later snapshot that no longer lists the row must not
    /// forget it — that is precisely the snapshot a terminal state races with.
    @Test("a snapshot that drops a row keeps the row's mapping")
    func ingestAccumulatesAcrossSnapshots() {
        let map = DownloadItemVideoIDMap()
        let item = ChatVideoIDMapFixture.item(ChatVideoIDMapFixture.first)
        map.ingest(ChatVideoIDMapFixture.snapshot(active: [item]))

        map.ingest(DownloadQueueSnapshot.empty)

        #expect(map.videoID(for: item.id) == ChatVideoIDMapFixture.first)
        #expect(map.count == 1)
    }

    /// Ingesting the same row twice is a no-op, not a second entry.
    @Test("re-ingesting the same row neither duplicates nor changes it")
    func repeatedIngestIsIdempotent() {
        let map = DownloadItemVideoIDMap()
        let item = ChatVideoIDMapFixture.item(ChatVideoIDMapFixture.first)

        map.ingest(ChatVideoIDMapFixture.snapshot(pending: [item]))
        map.ingest(ChatVideoIDMapFixture.snapshot(active: [item]))
        map.ingest(ChatVideoIDMapFixture.snapshot(active: [item]))

        #expect(map.count == 1)
        #expect(map.videoID(for: item.id) == ChatVideoIDMapFixture.first)
    }

    /// Malformed input: one snapshot carrying the same item id twice under different
    /// video ids. First write wins, deterministically, and the map still counts one.
    ///
    /// The queue cannot produce this — `id` is minted per enqueue — but the map is fed
    /// from a `@Sendable` seam whose payload it does not validate, and "the later row
    /// silently rewrites an in-flight correlation" is the wrong failure to inherit.
    @Test("a snapshot with duplicate item ids keeps the first correlation")
    func duplicateRowsKeepTheFirstCorrelation() {
        let map = DownloadItemVideoIDMap()
        let sharedID = UUID()
        let first = DownloadItem(
            id: sharedID,
            canonicalVideoID: ChatVideoIDMapFixture.first,
            sourceURL: URL(fileURLWithPath: "/tmp/first")
        )
        let second = DownloadItem(
            id: sharedID,
            canonicalVideoID: ChatVideoIDMapFixture.second,
            sourceURL: URL(fileURLWithPath: "/tmp/second")
        )

        map.ingest(ChatVideoIDMapFixture.snapshot(active: [first, second]))

        #expect(map.count == 1)
        #expect(map.videoID(for: sharedID) == ChatVideoIDMapFixture.first)
    }

    /// An active row and a pending row carrying the same id: the active half is read
    /// first, so it is the one that sticks.
    @Test("an id present in both halves keeps the active half's correlation")
    func activeHalfWinsOverPending() {
        let map = DownloadItemVideoIDMap()
        let sharedID = UUID()
        let active = DownloadItem(
            id: sharedID,
            canonicalVideoID: ChatVideoIDMapFixture.first,
            sourceURL: URL(fileURLWithPath: "/tmp/active")
        )
        let pending = DownloadItem(
            id: sharedID,
            canonicalVideoID: ChatVideoIDMapFixture.second,
            sourceURL: URL(fileURLWithPath: "/tmp/pending")
        )

        map.ingest(ChatVideoIDMapFixture.snapshot(active: [active], pending: [pending]))

        #expect(map.videoID(for: sharedID) == ChatVideoIDMapFixture.first)
    }

    @Test("prune removes exactly one correlation and leaves its siblings")
    func pruneRemovesOnlyItsOwnEntry() {
        let map = DownloadItemVideoIDMap()
        let doomed = ChatVideoIDMapFixture.item(ChatVideoIDMapFixture.first)
        let survivor = ChatVideoIDMapFixture.item(ChatVideoIDMapFixture.second)
        map.ingest(ChatVideoIDMapFixture.snapshot(active: [doomed, survivor]))

        map.prune(doomed.id)

        #expect(map.videoID(for: doomed.id) == nil)
        #expect(map.videoID(for: survivor.id) == ChatVideoIDMapFixture.second)
        #expect(map.count == 1)
    }

    /// Pruning an id the map never held, or pruning twice, changes nothing. The handler
    /// prunes after resolving a terminal state, and a duplicated terminal emission must
    /// not be able to disturb an unrelated row.
    @Test("pruning an unknown id, or the same id twice, is a no-op")
    func pruningUnknownIsHarmless() {
        let map = DownloadItemVideoIDMap()
        let item = ChatVideoIDMapFixture.item(ChatVideoIDMapFixture.third)
        map.ingest(ChatVideoIDMapFixture.snapshot(active: [item]))

        map.prune(UUID())
        #expect(map.count == 1)

        map.prune(item.id)
        map.prune(item.id)
        #expect(map.count == 0)
        #expect(map.videoID(for: item.id) == nil)
    }

    /// A pruned row that the queue publishes again — the same video re-queued after a
    /// cancel, which mints a NEW item id — correlates afresh rather than staying gone.
    @Test("a re-queued video correlates again under its new item id")
    func requeuedVideoCorrelatesAgain() {
        let map = DownloadItemVideoIDMap()
        let first = ChatVideoIDMapFixture.item(ChatVideoIDMapFixture.first)
        map.ingest(ChatVideoIDMapFixture.snapshot(active: [first]))
        map.prune(first.id)

        let retry = ChatVideoIDMapFixture.item(ChatVideoIDMapFixture.first)
        map.ingest(ChatVideoIDMapFixture.snapshot(pending: [retry]))

        #expect(retry.id != first.id)
        #expect(map.videoID(for: retry.id) == ChatVideoIDMapFixture.first)
        #expect(map.count == 1)
    }
}
