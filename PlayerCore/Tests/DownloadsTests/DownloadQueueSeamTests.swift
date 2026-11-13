// `FakeDownloadQueue` drives the whole ``DownloadQueueing`` contract without a process:
// normalization + dedup on enqueue, the playlist hold/confirm round-trip (including the
// stale-token zero outcome), and the snapshot seam firing after every mutation.
import Foundation
import PlayerCoreTestSupport
import Services
import Testing

@MainActor
@Suite("Download queue seam")
struct DownloadQueueSeamTests {
    static let firstVideo = "dQw4w9WgXcQ"
    static let secondVideo = "aBcDeFgHiJk"
    static let thirdVideo = "zzzzzzzzzzz"
    static let playlistLink = "https://www.youtube.com/playlist?list=PLabcdefghijk"

    static func makeQueue() -> (queue: FakeDownloadQueue, recorder: DownloadSeamRecorder) {
        let queue = FakeDownloadQueue()
        let recorder = DownloadSeamRecorder()
        queue.onQueueChanged = { recorder.record($0) }
        queue.onItemProgress = { _, state in recorder.record(state) }
        return (queue, recorder)
    }

    static func watchURL(_ videoID: String) throws -> URL {
        try downloadTestURL("https://youtu.be/\(videoID)")
    }

    @Test("the same video pasted in four families enqueues exactly once")
    func dedupAcrossFamilies() async throws {
        let (queue, recorder) = Self.makeQueue()
        let pasted = try [
            "https://www.youtube.com/watch?v=\(Self.firstVideo)",
            "https://youtu.be/\(Self.firstVideo)",
            "https://www.youtube.com/shorts/\(Self.firstVideo)",
            "https://music.youtube.com/watch?v=\(Self.firstVideo)",
        ].map(downloadTestURL)

        let outcome = await queue.enqueue(urls: pasted)
        #expect(outcome.added == 1)
        #expect(outcome.duplicatesDropped == 3)
        #expect(outcome.pendingPlaylist == nil)
        #expect(queue.pendingItems.map(\.canonicalVideoID) == [Self.firstVideo])
        #expect(recorder.latestSnapshot?.pendingItems.count == 1)
    }

    @Test("URLs that name neither a video nor a playlist are ignored")
    func junkIsIgnored() async throws {
        let (queue, _) = Self.makeQueue()
        let pasted = try [
            "https://vimeo.com/watch?v=\(Self.firstVideo)",
            "https://www.youtube.com/",
            "https://www.youtube.com/watch?v=tooshort&list=PLabcdefghijk",
        ].map(downloadTestURL)

        let outcome = await queue.enqueue(urls: pasted)
        #expect(outcome == .zero)
        #expect(queue.pendingItems.isEmpty)
    }

    /// The precedence rule at the queue level: a `watch?v=…&list=…` paste queues ONE
    /// row and offers NO playlist confirmation, even when an expansion is available.
    @Test("a share link carrying a list never becomes a playlist confirmation")
    func shareLinkDoesNotExpand() async throws {
        let (queue, _) = Self.makeQueue()
        let shareLink = try downloadTestURL(
            "https://www.youtube.com/watch?v=\(Self.firstVideo)&list=PLabcdefghijk&index=4"
        )
        queue.playlistExpansion = [shareLink: Array(repeating: Self.secondVideo, count: 50)]

        let outcome = await queue.enqueue(urls: [shareLink])
        #expect(outcome.added == 1)
        #expect(outcome.pendingPlaylist == nil)
        #expect(queue.pendingItems.count == 1)
    }

    @Test("a playlist is held until confirmed, then appended")
    func playlistHoldAndConfirm() async throws {
        let (queue, _) = Self.makeQueue()
        let playlist = try downloadTestURL(Self.playlistLink)
        queue.playlistExpansion = [playlist: [Self.firstVideo, Self.secondVideo]]

        let held = await queue.enqueue(urls: [playlist])
        #expect(held.added == 0)
        #expect(queue.pendingItems.isEmpty)
        let pending = try #require(held.pendingPlaylist)
        #expect(pending.count == 2)
        #expect(pending.capped == false)

        let confirmed = await queue.confirmPlaylist(pending.token)
        #expect(confirmed.added == 2)
        #expect(queue.pendingItems.map(\.canonicalVideoID) == [Self.firstVideo, Self.secondVideo])
    }

    @Test("expansion is capped at the plan's playlist ceiling")
    func playlistExpansionIsCapped() async throws {
        let (queue, _) = Self.makeQueue()
        let playlist = try downloadTestURL(Self.playlistLink)
        let oversized = (0 ..< (DownloadQueueLimits.maxPlaylistExpansion + 25))
            .map { String(format: "vid%08d", $0) }
        queue.playlistExpansion = [playlist: oversized]

        let held = await queue.enqueue(urls: [playlist])
        let pending = try #require(held.pendingPlaylist)
        #expect(pending.capped)
        #expect(pending.count == DownloadQueueLimits.maxPlaylistExpansion)
    }

    /// A discarded confirmation must read as "0 added", never as an error.
    @Test("a stale playlist token returns the zero outcome")
    func stalePlaylistTokenIsZero() async {
        let (queue, _) = Self.makeQueue()
        let outcome = await queue.confirmPlaylist(UUID())
        #expect(outcome == .zero)
        #expect(queue.pendingItems.isEmpty)
    }

    @Test("confirming the same token twice adds nothing the second time")
    func confirmationIsSingleUse() async throws {
        let (queue, _) = Self.makeQueue()
        let playlist = try downloadTestURL(Self.playlistLink)
        queue.playlistExpansion = [playlist: [Self.firstVideo]]
        let held = await queue.enqueue(urls: [playlist])
        let pending = try #require(held.pendingPlaylist)

        let first = await queue.confirmPlaylist(pending.token)
        let second = await queue.confirmPlaylist(pending.token)
        #expect(first.added == 1)
        #expect(second == .zero)
    }

    @Test("a mixed paste reports singles, duplicates, and the playlist at once")
    func mixedPasteReportsEveryFact() async throws {
        let (queue, _) = Self.makeQueue()
        let playlist = try downloadTestURL(Self.playlistLink)
        queue.playlistExpansion = [playlist: ["mixaaaaaaaa", "mixbbbbbbbb"]]
        let pasted = try [
            Self.watchURL(Self.firstVideo),
            downloadTestURL("https://www.youtube.com/watch?v=\(Self.firstVideo)"),
            Self.watchURL(Self.secondVideo),
            playlist,
        ]

        let outcome = await queue.enqueue(urls: pasted)
        #expect(outcome.added == 2)
        #expect(outcome.duplicatesDropped == 1)
        #expect(outcome.pendingPlaylist?.count == 2)
    }

    @Test("pause latches paused, stops refilling, and leaves the in-flight row alone")
    func pauseStopsRefillWithoutTouchingTheInFlightRow() async throws {
        let (queue, recorder) = Self.makeQueue()
        let pasted = try [Self.watchURL(Self.firstVideo), Self.watchURL(Self.secondVideo)]
        _ = await queue.enqueue(urls: pasted)
        queue.startNext()
        let inFlight = try #require(queue.activeItems.first)
        #expect(inFlight.canonicalVideoID == Self.firstVideo)

        queue.pause()
        #expect(queue.isPaused)
        #expect(queue.activeItems.map(\.canonicalVideoID) == [Self.firstVideo])
        #expect(queue.pendingItems.map(\.canonicalVideoID) == [Self.secondVideo])
        #expect(recorder.latestSnapshot?.isPaused == true)

        queue.startNext()
        #expect(queue.activeItems.map(\.canonicalVideoID) == [Self.firstVideo])

        queue.finish(id: inFlight.id, state: .finished(fileURL: URL(fileURLWithPath: "/tmp/a.m4a")))
        queue.startNext()
        #expect(queue.activeItems.isEmpty)

        queue.resume()
        queue.startNext()
        #expect(queue.activeItems.map(\.canonicalVideoID) == [Self.secondVideo])
    }

    @Test("pending rows can be reordered and removed; the in-flight row cannot")
    func reorderAndRemovePending() async throws {
        let (queue, _) = Self.makeQueue()
        let pasted = try [
            Self.watchURL(Self.firstVideo),
            Self.watchURL(Self.secondVideo),
            Self.watchURL(Self.thirdVideo),
        ]
        _ = await queue.enqueue(urls: pasted)
        queue.startNext()
        let current = try #require(queue.activeItems.first)
        let last = try #require(queue.pendingItems.last)

        queue.movePending(last.id, to: 0)
        #expect(queue.pendingItems.map(\.canonicalVideoID) == [Self.thirdVideo, Self.secondVideo])

        queue.removePending(current.id)
        #expect(queue.activeItems.map(\.id) == [current.id])

        let head = try #require(queue.pendingItems.first)
        queue.removePending(head.id)
        #expect(queue.pendingItems.map(\.canonicalVideoID) == [Self.secondVideo])
    }

    @Test("progress and completion publish through the row seam")
    func rowSeamPublishesProgressAndCompletion() async throws {
        let (queue, recorder) = Self.makeQueue()
        _ = try await queue.enqueue(urls: [Self.watchURL(Self.firstVideo)])
        queue.startNext()
        let item = try #require(queue.activeItems.first)

        queue.emitProgress(id: item.id, state: .downloading(fraction: 0.5, speedBytesPerSec: 2048, etaSeconds: 4))
        let finished = DownloadState.finished(fileURL: URL(fileURLWithPath: "/tmp/song.m4a"))
        queue.finish(id: item.id, state: finished)

        #expect(recorder.recordedProgress.count == 3)
        #expect(recorder.recordedProgress.first == .fetchingMetadata)
        #expect(recorder.recordedProgress.last == finished)
        #expect(queue.activeItems.isEmpty)
    }

    @Test("cancelCurrent drops the in-flight row and reports it cancelled")
    func cancelCurrentReportsCancellation() async throws {
        let (queue, recorder) = Self.makeQueue()
        _ = try await queue.enqueue(urls: [Self.watchURL(Self.firstVideo)])
        queue.startNext()

        queue.cancelCurrent()
        #expect(queue.activeItems.isEmpty)
        #expect(recorder.recordedProgress.last == .cancelled)
        #expect(queue.cancelCurrentCallCount == 1)
    }

    @Test("cancelAll empties the queue and drops held playlists")
    func cancelAllClearsEverything() async throws {
        let (queue, recorder) = Self.makeQueue()
        let playlist = try downloadTestURL(Self.playlistLink)
        queue.playlistExpansion = [playlist: [Self.secondVideo]]
        let pasted = try [Self.watchURL(Self.firstVideo), playlist]
        _ = await queue.enqueue(urls: pasted)
        let pending = try #require(queue.heldPlaylistToken)
        queue.startNext()

        queue.cancelAll()
        #expect(queue.activeItems.isEmpty)
        #expect(queue.pendingItems.isEmpty)
        #expect(recorder.latestSnapshot?.isEmpty == true)

        let stale = await queue.confirmPlaylist(pending)
        #expect(stale == .zero)
    }

    /// The double must settle a row in the production driver's order, because every
    /// drain-scoped observer downstream depends on it.
    ///
    /// `settle(_:)` (`DownloadQueueService+Driver.swift`) does `active.removeAll` →
    /// `emitItemState` → `emitQueueChanged`, so the terminal state of a drain's LAST row
    /// is published while the queue still reads non-empty and the empty snapshot arrives
    /// after it. An observer that counts terminal states and assesses the drain on the
    /// empty snapshot — which is what `DownloadToastPolicy` does — reports one row fewer
    /// per drain if the two are inverted, and carries the missing one into the next
    /// drain. This double DID invert them, so any test driven through it reproduced the
    /// off-by-one `440a59b` had already fixed in production.
    ///
    /// The assertion is on the interleaving, not on each seam separately: the two rows
    /// still in flight when the first settles are what make "still non-empty" a claim
    /// about parallelism rather than about a queue with pending work behind it.
    @Test("a settled row publishes its terminal state before the snapshot that drops it")
    func settledRowPublishesStateBeforeSnapshot() async throws {
        let queue = FakeDownloadQueue(maxConcurrent: 3)
        let log = SeamOrderLog()
        queue.onQueueChanged = { snapshot in
            log.append("snapshot(active: \(snapshot.activeItems.count))")
        }
        queue.onItemProgress = { _, state in
            if case .finished = state { log.append("finished") }
        }

        let pasted = try [
            Self.watchURL(Self.firstVideo),
            Self.watchURL(Self.secondVideo),
            Self.watchURL(Self.thirdVideo),
        ]
        _ = await queue.enqueue(urls: pasted)
        queue.startNext()
        queue.startNext()
        queue.startNext()
        let ids = queue.activeItems.map(\.id)
        log.reset()

        for id in ids {
            queue.finish(id: id, state: .finished(fileURL: URL(fileURLWithPath: "/tmp/\(id).m4a")))
        }

        #expect(log.recorded == [
            "finished", "snapshot(active: 2)",
            "finished", "snapshot(active: 1)",
            "finished", "snapshot(active: 0)",
        ])
    }
}

/// Both seams in ONE list, in arrival order. ``DownloadSeamRecorder`` keeps a log per
/// seam, which cannot express the interleaving BETWEEN them — and that interleaving is
/// the whole of what `settle(_:)` promises.
private final class SeamOrderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func append(_ entry: String) {
        lock.withLock { entries.append(entry) }
    }

    func reset() {
        lock.withLock { entries.removeAll() }
    }

    var recorded: [String] {
        lock.withLock { entries }
    }
}
