import Foundation
import PlayerCoreTestSupport
import Services
import Testing
@testable import ViewModels

/// Wires a ``FakeDownloadQueue`` into a ``DownloadQueueStore`` exactly the way the
/// composition root will: the sequence is stamped at CAPTURE time, inside the
/// `@Sendable` seam closure, before the hop that could reorder two snapshots.
@MainActor
final class DownloadsViewModelHarness {
    let queue = FakeDownloadQueue()
    let store = DownloadQueueStore()
    let model: DownloadsViewModel

    private var sequence = 0

    init() {
        model = DownloadsViewModel(queue: queue, store: store)
        queue.onQueueChanged = { [weak self] snapshot in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sequence += 1
                self.store.ingest(sequence: self.sequence, snapshot: snapshot)
            }
        }
        queue.onItemProgress = { [weak self] id, state in
            MainActor.assumeIsolated { self?.store.ingestProgress(id: id, state: state) }
        }
    }
}

/// Todo 10 acceptance: the view model projects the store into display rows, reports a
/// paste through ONE struct that carries the counts and the pending playlist at the
/// same time, and forwards every queue intent to `any DownloadQueueing`.
@MainActor
struct DownloadsViewModelTests {
    private static let firstVideo = "dQw4w9WgXcQ"
    private static let secondVideo = "9bZkp7q19f0"
    private static let playlistLink = "https://www.youtube.com/playlist?list=PLabcdefghijk"

    private static func watchURL(_ videoID: String) -> URL {
        URL(string: "https://www.youtube.com/watch?v=\(videoID)") ?? URL(fileURLWithPath: videoID)
    }

    // MARK: Row projection

    @Test func rowsSplitIntoActiveLeavesAndPendingValuesInQueueOrder() async {
        let harness = DownloadsViewModelHarness()
        _ = await harness.queue.enqueue(urls: [
            Self.watchURL(Self.firstVideo),
            Self.watchURL(Self.secondVideo),
        ])
        harness.queue.startNext()

        #expect(harness.model.activeRows.map(\.canonicalVideoID) == [Self.firstVideo])
        #expect(harness.model.pendingRows.map(\.title) == [Self.secondVideo])
        #expect(harness.model.hasActiveDownloads)
    }

    @Test func rowTitleFallsBackToTheCanonicalIDUntilMetadataLands() throws {
        let harness = DownloadsViewModelHarness()
        var item = downloadQueueTestItem(Self.firstVideo)

        harness.store.ingest(sequence: 0, snapshot: DownloadQueueSnapshot(
            activeItems: [item], pendingItems: [], isPaused: false
        ))
        let leaf = try #require(harness.model.activeRows.first)
        #expect(leaf.title == Self.firstVideo)
        #expect(leaf.uploader == nil)

        item.title = "Never Gonna Give You Up"
        item.uploader = "Rick Astley"
        harness.store.ingest(sequence: 1, snapshot: DownloadQueueSnapshot(
            activeItems: [item], pendingItems: [], isPaused: false
        ))
        #expect(leaf.title == "Never Gonna Give You Up")
        #expect(leaf.uploader == "Rick Astley")
    }

    /// A PENDING row's ``DownloadRow/state`` is the last QUEUE-MUTATION state and there
    /// is no live sample for it at all; an ACTIVE row's live sample lands on its own
    /// leaf, which is what keeps a progress tick out of the list body.
    @Test func liveSamplesLandOnTheLeafAndNotOnPendingRows() throws {
        let harness = DownloadsViewModelHarness()
        let active = downloadQueueTestItem(Self.firstVideo)
        let pending = downloadQueueTestItem(Self.secondVideo)
        harness.store.ingest(sequence: 0, snapshot: DownloadQueueSnapshot(
            activeItems: [active], pendingItems: [pending], isPaused: false
        ))

        harness.store.ingestProgress(
            id: active.id,
            state: .downloading(fraction: 0.42, speedBytesPerSec: nil, etaSeconds: nil)
        )

        #expect(try #require(harness.model.activeRows.first).fraction == 0.42)
        #expect(harness.model.pendingRows.map(\.state) == [.queued])
    }

    @Test func pendingRowsStayInsideTheDisplayWindowAndReportOverflow() {
        let harness = DownloadsViewModelHarness()
        let limit = DownloadQueueStore.displayWindowLimit
        let pending = (0 ..< (limit + 7)).map { downloadQueueTestItem("v\($0)") }

        harness.store.ingest(sequence: 0, snapshot: DownloadQueueSnapshot(
            activeItems: [downloadQueueTestItem("cur")], pendingItems: pending, isPaused: false
        ))

        #expect(harness.model.activeRows.count == 1)
        #expect(harness.model.pendingRows.count == limit)
        #expect(harness.model.pendingOverflow == 7)
        #expect(harness.model.count == limit + 8)
    }

    @Test func emptyQueueProjectsNoRows() {
        let harness = DownloadsViewModelHarness()
        #expect(harness.model.activeRows.isEmpty)
        #expect(harness.model.pendingRows.isEmpty)
        #expect(!harness.model.hasActiveDownloads)
        #expect(harness.model.isEmpty)
        #expect(!harness.model.isWorking)
    }

    /// An engine update must be refused while a transfer is running, and pausing does
    /// not stop a running transfer — so `hasActiveDownloads` has to stay `true` where
    /// `isWorking` goes `false`. Two booleans one line apart; this pins which is which.
    @Test func pausingLeavesActiveDownloadsActiveButNotWorking() async {
        let harness = DownloadsViewModelHarness()
        _ = await harness.model.enqueue(urls: [Self.watchURL(Self.firstVideo)])
        harness.queue.startNext()
        #expect(harness.model.isWorking)

        harness.model.pause()

        #expect(!harness.model.isWorking)
        #expect(harness.model.hasActiveDownloads)
        #expect(harness.model.isPaused)
    }

    /// QA scenario (happy path): a scripted queue lifecycle renders the right row
    /// state at every step, and the live sample stays on the row's own leaf.
    @Test func scriptedLifecycleRendersCorrectRowStates() async throws {
        let harness = DownloadsViewModelHarness()
        _ = await harness.model.enqueue(urls: [
            Self.watchURL(Self.firstVideo),
            Self.watchURL(Self.secondVideo),
        ])
        #expect(harness.model.activeRows.isEmpty)
        #expect(harness.model.pendingRows.map(\.state) == [.queued, .queued])

        harness.queue.startNext()
        let started = try #require(harness.model.activeRows.first)
        #expect(started.state == .fetchingMetadata)
        #expect(harness.model.pendingRows.count == 1)

        harness.queue.emitProgress(
            id: started.id,
            state: .downloading(fraction: 0.5, speedBytesPerSec: 2048, etaSeconds: 9)
        )
        #expect(started.fraction == 0.5)

        harness.queue.finish(id: started.id, state: .finished(fileURL: URL(fileURLWithPath: "/tmp/out.m4a")))
        #expect(harness.model.activeRows.isEmpty)
        #expect(harness.model.count == 1)

        harness.queue.startNext()
        #expect(harness.model.activeRows.map(\.state) == [.fetchingMetadata])
        #expect(harness.model.pendingRows.isEmpty)
    }

    // MARK: Paste report

    @Test func pasteReportCarriesAddedAndDuplicateCounts() async {
        let harness = DownloadsViewModelHarness()
        let report = await harness.model.enqueue(urls: [
            Self.watchURL(Self.firstVideo),
            Self.watchURL(Self.secondVideo),
            Self.watchURL(Self.firstVideo),
        ])

        #expect(report.added == 2)
        #expect(report.duplicatesDropped == 1)
        #expect(!report.needsConfirmation)
        #expect(!report.isEmpty)
    }

    /// One paste routinely mixes singles with a playlist, so the report must carry the
    /// counts AND the held expansion simultaneously.
    @Test func pasteReportCarriesCountsAndPendingPlaylistTogether() async throws {
        let harness = DownloadsViewModelHarness()
        let playlist = try #require(URL(string: Self.playlistLink))
        harness.queue.playlistExpansion[playlist] = ["aaaaaaaaaaa", "bbbbbbbbbbb"]

        let report = await harness.model.enqueue(urls: [Self.watchURL(Self.firstVideo), playlist])

        #expect(report.added == 1)
        #expect(report.needsConfirmation)
        let pendingPlaylist = try #require(report.pendingPlaylist)
        #expect(pendingPlaylist.count == 2)
        #expect(!pendingPlaylist.capped)
    }

    @Test func confirmingTheHeldPlaylistQueuesItsEntries() async throws {
        let harness = DownloadsViewModelHarness()
        let playlist = try #require(URL(string: Self.playlistLink))
        harness.queue.playlistExpansion[playlist] = ["aaaaaaaaaaa", "bbbbbbbbbbb"]

        let paste = await harness.model.enqueue(urls: [playlist])
        let token = try #require(paste.pendingPlaylist?.token)
        let confirmed = await harness.model.confirmPlaylist(token)

        #expect(confirmed.added == 2)
        #expect(harness.model.count == 2)
    }

    @Test func staleConfirmationReportsZero() async {
        let harness = DownloadsViewModelHarness()
        let report = await harness.model.confirmPlaylist(UUID())

        #expect(report == .zero)
        #expect(report.isEmpty)
    }

    @Test func pasteOfJunkReportsNothing() async {
        let harness = DownloadsViewModelHarness()
        let junk = URL(string: "https://vimeo.com/12345") ?? URL(fileURLWithPath: "junk")
        let report = await harness.model.enqueue(urls: [junk])

        #expect(report.isEmpty)
        #expect(harness.model.isEmpty)
    }

    // MARK: Queue intents

    @Test func removeAndMoveForwardToTheQueueSeam() async {
        let harness = DownloadsViewModelHarness()
        _ = await harness.model.enqueue(urls: [
            Self.watchURL(Self.firstVideo),
            Self.watchURL(Self.secondVideo),
        ])
        let rows = harness.model.pendingRows
        #expect(rows.count == 2)

        harness.model.move(rows[1].id, to: 0)
        #expect(harness.model.pendingRows.map(\.id) == [rows[1].id, rows[0].id])

        harness.model.remove(rows[1].id)
        #expect(harness.model.pendingRows.map(\.id) == [rows[0].id])
    }

    @Test func pauseResumeAndToggleForwardToTheQueueSeam() {
        let harness = DownloadsViewModelHarness()

        harness.model.pause()
        #expect(harness.queue.pauseCallCount == 1)
        #expect(harness.model.isPaused)

        harness.model.resume()
        #expect(harness.queue.resumeCallCount == 1)
        #expect(!harness.model.isPaused)

        harness.model.togglePaused()
        #expect(harness.queue.pauseCallCount == 2)

        harness.model.togglePaused()
        #expect(harness.queue.resumeCallCount == 2)
    }

    @Test func cancelIntentsForwardToTheQueueSeam() async throws {
        let harness = DownloadsViewModelHarness()
        _ = await harness.model.enqueue(urls: [
            Self.watchURL(Self.firstVideo),
            Self.watchURL(Self.secondVideo),
        ])
        harness.queue.startNext()

        let inFlight = try #require(harness.model.activeRows.first?.id)
        harness.model.cancel(inFlight)
        #expect(harness.queue.cancelledItemIDs == [inFlight])
        #expect(harness.model.activeRows.isEmpty)

        harness.model.cancelAll()
        #expect(harness.queue.cancelAllCallCount == 1)
        #expect(harness.model.isEmpty)
    }
}
