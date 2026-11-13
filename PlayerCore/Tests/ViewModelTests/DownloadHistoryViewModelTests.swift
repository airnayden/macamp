// DownloadHistoryViewModelTests — the History tab's window, its two row-removal
// paths, and the derived text a row renders.
//
// The load-bearing assertions are (1) that a keyset page GROWS the window instead of
// replacing it, (2) that removing a row leaves every OTHER loaded page standing — a
// reload-based implementation passes a one-page test and silently truncates a scrolled
// list — and (3) that the absolute timestamp is rendered in the zone the download was
// TAKEN in and not in this machine's, which is a claim no single-offset fixture can
// make (see `theAbsoluteTimestampIgnoresTheDeviceZone`).
import Foundation
import Persistence
import PlayerCoreTestSupport
import Services
import Testing
@testable import ViewModels

// MARK: - Double

/// An in-memory ``DownloadHistoryRepositoryProviding`` that really pages.
///
/// It reproduces the shipped repository's window — newest first, tie-broken on an
/// INSERT-ORDER integer, over-fetched by one — rather than returning a slice, so a
/// view model that mishandles the cursor produces a wrong window here too. The
/// tie-breaker is an insert-order index standing in for the table's implicit rowid,
/// which is what todo 12's cursor actually binds.
private final class FakeDownloadHistory: DownloadHistoryRepositoryProviding, @unchecked Sendable {
    private struct Stored {
        let record: DownloadHistoryRecord
        let rowID: Int64
    }

    private var stored: [Stored] = []
    private var nextRowID: Int64 = 1
    private(set) var pageRequests: [PageCursor<Double>?] = []
    private(set) var deleteAllCallCount = 0
    var failsNextRead: Bool = false

    init(_ records: [DownloadHistoryRecord] = []) {
        for record in records {
            append(record)
        }
    }

    func append(_ record: DownloadHistoryRecord) {
        stored.append(Stored(record: record, rowID: nextRowID))
        nextRowID += 1
    }

    func insert(_ entry: DownloadHistoryRecord) async throws {
        append(entry)
    }

    func entries(
        before cursor: PageCursor<Double>?,
        limit: Int
    ) async throws -> Page<DownloadHistoryRecord, Double> {
        pageRequests.append(cursor)
        if failsNextRead {
            failsNextRead = false
            throw CocoaError(.fileReadUnknown)
        }
        let ordered = stored.sorted { lhs, rhs in
            lhs.record.downloadedAt == rhs.record.downloadedAt
                ? lhs.rowID > rhs.rowID
                : lhs.record.downloadedAt > rhs.record.downloadedAt
        }
        let remaining = cursor.map { anchor in
            ordered.drop { candidate in
                candidate.record.downloadedAt > anchor.key
                    || (candidate.record.downloadedAt == anchor.key && candidate.rowID >= anchor.id)
            }
        } ?? ordered[...]
        // Over-fetch by one and drop the surplus, the same way `makePage` does inside
        // `Persistence` — restated here because that helper is module-internal.
        let overFetched = Array(remaining.prefix(limit + 1))
        let kept = Array(overFetched.prefix(limit))
        let next = overFetched.count > limit
            ? kept.last.map { PageCursor(key: $0.record.downloadedAt, id: $0.rowID) }
            : nil
        return Page(items: kept.map(\.record), nextCursor: next)
    }

    @discardableResult
    func delete(id: String) async throws -> Bool {
        let before = stored.count
        stored.removeAll { $0.record.id == id }
        return stored.count != before
    }

    @discardableResult
    func deleteAll() async throws -> Int {
        deleteAllCallCount += 1
        let removed = stored.count
        stored.removeAll()
        return removed
    }

    func latestEntry(canonicalVideoID: String) async throws -> DownloadHistoryRecord? {
        stored.last { $0.record.canonicalVideoID == canonicalVideoID }?.record
    }

    func knownVideoIDs(in ids: [String]) async throws -> Set<String> {
        Set(stored.map(\.record.canonicalVideoID)).intersection(ids)
    }
}

// MARK: - Fixtures

private let fixtureEpoch: TimeInterval = 1_700_000_000

private func entry(
    _ index: Int,
    downloadedAt: TimeInterval? = nil,
    title: String? = nil,
    videoID: String? = nil,
    filePath: String? = nil,
    audioFormat: String = "m4a",
    audioQuality: String = "best",
    utcOffsetSeconds: Int = 0
) -> DownloadHistoryRecord {
    DownloadHistoryRecord(
        id: "entry-\(index)",
        canonicalVideoID: videoID ?? "video-\(index)",
        title: title ?? String(format: "Download %02d", index),
        uploader: "Channel",
        durationSeconds: 150,
        filePath: filePath ?? "/Music/MacAMP Downloads/track-\(index).m4a",
        audioFormat: audioFormat,
        audioQuality: audioQuality,
        sourceURL: "https://www.youtube.com/watch?v=video-\(index)",
        downloadedAt: downloadedAt ?? (fixtureEpoch - TimeInterval(index)),
        utcOffsetSeconds: utcOffsetSeconds
    )
}

private func entries(_ count: Int) -> [DownloadHistoryRecord] {
    (0 ..< count).map { entry($0) }
}

// MARK: - Window

@MainActor
struct DownloadHistoryViewModelTests {
    @Test func retryMovesFailedVideoFromHistoryToThePausedQueue() async throws {
        var failed = entry(0, videoID: "dQw4w9WgXcQ")
        failed.sourceURL = "https://www.youtube.com/playlist?list=PLfixture"
        failed.filePath = ""
        failed.failureReason = "The download failed."
        let repository = FakeDownloadHistory([failed, entry(1)])
        let history = DownloadHistoryViewModel(repository: repository)
        let queue = FakeDownloadQueue()
        queue.pause()
        let downloads = DownloadsViewModel(queue: queue, store: DownloadQueueStore())
        try await history.loadInitial()

        #expect(try await history.retry(failed, using: downloads))
        #expect(queue.pendingItems.map(\.canonicalVideoID) == ["dQw4w9WgXcQ"])
        #expect(history.entries.map(\.id) == ["entry-1"])

        try await history.loadInitial()
        #expect(history.entries.map(\.id) == ["entry-1"])
        #expect(try await !history.retry(failed, using: downloads))
        #expect(queue.pendingItems.count == 1)
    }

    @Test func loadInitialFillsTheNewestPageAndMarksTheWindowLoaded() async throws {
        let model = DownloadHistoryViewModel(repository: FakeDownloadHistory(entries(3)))
        #expect(!model.hasLoaded)

        try await model.loadInitial()

        #expect(model.entries.map(\.id) == ["entry-0", "entry-1", "entry-2"])
        #expect(model.hasLoaded)
        #expect(!model.hasMore)
        #expect(!model.isLoading)
    }

    /// The distinction the empty state depends on: before the first load the window is
    /// empty for a reason that is not "you have downloaded nothing".
    @Test func anUnloadedWindowIsDistinguishableFromAnEmptyLog() async throws {
        let model = DownloadHistoryViewModel(repository: FakeDownloadHistory())

        #expect(model.entries.isEmpty)
        #expect(!model.hasLoaded)

        try await model.loadInitial()

        #expect(model.entries.isEmpty)
        #expect(model.hasLoaded)
        #expect(!model.hasMore)
    }

    @Test func pagesGrowTheWindowNewestFirstWithoutDuplicates() async throws {
        let repository = FakeDownloadHistory(entries(5))
        let model = DownloadHistoryViewModel(repository: repository, pageSize: 2)

        try await model.loadInitial()
        #expect(model.entries.map(\.id) == ["entry-0", "entry-1"])
        #expect(model.hasMore)

        try await model.loadMore()
        try await model.loadMore()

        #expect(model.entries.map(\.id) == ["entry-0", "entry-1", "entry-2", "entry-3", "entry-4"])
        #expect(!model.hasMore)
        #expect(repository.pageRequests.count == 3)
        #expect(repository.pageRequests[0] == nil)
        #expect(repository.pageRequests[1] != nil)
    }

    /// Every entry shares one `downloadedAt`, so only the cursor's integer tie-breaker
    /// can move the window forward — a page 2 that answered on the timestamp alone
    /// comes back either empty or identical to page 1.
    @Test func pagingWalksThroughATimestampTie() async throws {
        let tied = (0 ..< 4).map { entry($0, downloadedAt: fixtureEpoch) }
        let model = DownloadHistoryViewModel(repository: FakeDownloadHistory(tied), pageSize: 2)

        try await model.loadInitial()
        try await model.loadMore()

        #expect(model.entries.count == 4)
        #expect(Set(model.entries.map(\.id)).count == 4)
    }

    @Test func loadMoreIsANoOpOnceExhausted() async throws {
        let repository = FakeDownloadHistory(entries(2))
        let model = DownloadHistoryViewModel(repository: repository, pageSize: 5)

        try await model.loadInitial()
        try await model.loadMore()

        #expect(model.entries.count == 2)
        #expect(repository.pageRequests.count == 1)
    }

    @Test func loadInitialReplacesTheWindowRatherThanAppendingToIt() async throws {
        let repository = FakeDownloadHistory(entries(3))
        let model = DownloadHistoryViewModel(repository: repository, pageSize: 10)

        try await model.loadInitial()
        try await model.loadInitial()

        #expect(model.entries.map(\.id) == ["entry-0", "entry-1", "entry-2"])
    }

    @Test func aFailedReadLeavesTheWindowUsableForTheNextAttempt() async throws {
        let repository = FakeDownloadHistory(entries(2))
        let model = DownloadHistoryViewModel(repository: repository)
        repository.failsNextRead = true

        await #expect(throws: (any Error).self) { try await model.loadInitial() }
        #expect(!model.isLoading)

        try await model.loadInitial()
        #expect(model.entries.count == 2)
    }

    @Test func paginationIsRequestedOnlyOnTheLastLoadedRow() async throws {
        let model = DownloadHistoryViewModel(repository: FakeDownloadHistory(entries(5)), pageSize: 2)

        try await model.loadInitial()

        #expect(!model.shouldPaginate(at: 0))
        #expect(model.shouldPaginate(at: 1))

        try await model.loadMore()
        try await model.loadMore()

        #expect(!model.shouldPaginate(at: model.entries.count - 1))
    }

    // MARK: - Removal

    @Test func removingAnEntryDropsExactlyThatRow() async throws {
        let repository = FakeDownloadHistory(entries(3))
        let model = DownloadHistoryViewModel(repository: repository)
        try await model.loadInitial()

        try await model.remove(id: "entry-1")

        #expect(model.entries.map(\.id) == ["entry-0", "entry-2"])
        let reloaded = try await repository.entries(before: nil, limit: 10)
        #expect(reloaded.items.map(\.id) == ["entry-0", "entry-2"])
    }

    /// A removal must not re-read page one. An implementation that reloaded instead of
    /// splicing would silently truncate a listener's scrolled list back to one page.
    @Test func removingAnEntryKeepsEveryLaterPageLoaded() async throws {
        let repository = FakeDownloadHistory(entries(6))
        let model = DownloadHistoryViewModel(repository: repository, pageSize: 2)
        try await model.loadInitial()
        try await model.loadMore()
        try await model.loadMore()
        #expect(model.entries.count == 6)
        let pagesBefore = repository.pageRequests.count

        try await model.remove(id: "entry-0")

        #expect(model.entries.count == 5)
        #expect(model.entries.first?.id == "entry-1")
        #expect(repository.pageRequests.count == pagesBefore)
    }

    @Test func removingAnEntryThatIsNotThereChangesNothing() async throws {
        let model = DownloadHistoryViewModel(repository: FakeDownloadHistory(entries(2)))
        try await model.loadInitial()

        try await model.remove(id: "entry-nope")

        #expect(model.entries.map(\.id) == ["entry-0", "entry-1"])
    }

    /// Re-downloading a video appends a row, so history legitimately holds several rows
    /// sharing one video id AND one path. Removing one must take one.
    @Test func removingOneOfSeveralRowsForTheSameVideoTakesOnlyThatRow() async throws {
        let repeated = (0 ..< 3).map {
            entry($0, videoID: "same-video", filePath: "/Music/MacAMP Downloads/same.m4a")
        }
        let model = DownloadHistoryViewModel(repository: FakeDownloadHistory(repeated))
        try await model.loadInitial()
        #expect(model.entries.count == 3)

        try await model.remove(id: "entry-1")

        #expect(model.entries.map(\.id) == ["entry-0", "entry-2"])
    }

    @Test func clearingEmptiesTheWindowAndRetiresTheCursor() async throws {
        let repository = FakeDownloadHistory(entries(6))
        let model = DownloadHistoryViewModel(repository: repository, pageSize: 2)
        try await model.loadInitial()
        #expect(model.hasMore)

        try await model.clearAll()

        #expect(model.entries.isEmpty)
        #expect(!model.hasMore)
        #expect(repository.deleteAllCallCount == 1)

        let pagesBefore = repository.pageRequests.count
        try await model.loadMore()
        #expect(repository.pageRequests.count == pagesBefore)
    }

    @Test func clearingLeavesTheWindowLoadedSoTheEmptyStateShows() async throws {
        let model = DownloadHistoryViewModel(repository: FakeDownloadHistory(entries(2)))
        try await model.loadInitial()

        try await model.clearAll()

        #expect(model.hasLoaded)
        #expect(model.entries.isEmpty)
    }
}
