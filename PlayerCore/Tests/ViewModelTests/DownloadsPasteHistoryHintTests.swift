// DownloadsPasteHistoryHintTests — todo 15 acceptance: the paste's advisory
// "you already downloaded some of these" count.
//
// The load-bearing assertion in this file is NOT the count. It is
// `theEnqueueOutcomeIsByteIdenticalWithAndWithoutTheHint`: the hint is allowed to be
// wrong, late or absent, and must never be allowed to change what the queue accepted.
// That test runs one identical paste through two models — one with a history log that
// answers, one with none — and compares the `EnqueueOutcome` values the queue itself
// returned, field for field.
//
// A byte-identical assertion is vacuous if the advisory path never ran, so every such
// test also asserts the lookup DID happen (`batches.count == 1`). That is the standing
// lesson this epic has now recorded ten times, applied up front rather than after a
// false pass.
import Foundation
import GRDB
import Persistence
import PlayerCoreTestSupport
import Services
import Testing
@testable import ViewModels

// MARK: - Doubles

/// A ``DownloadHistoryRepositoryProviding`` that records every batch it is asked about.
///
/// It answers `knownVideoIDs(in:)` from a seeded set and records the ARRAY it received,
/// so a test can assert both the answer and the shape of the question — one batch, in
/// paste order, capped. Every other method is unreachable from the hint and traps, so a
/// hint that grew a second database call fails loudly instead of silently passing.
private final class RecordingDownloadHistory: DownloadHistoryRepositoryProviding, @unchecked Sendable {
    private(set) var batches: [[String]] = []
    private let known: Set<String>
    private let failure: (any Error)?

    init(known: Set<String> = [], failure: (any Error)? = nil) {
        self.known = known
        self.failure = failure
    }

    func knownVideoIDs(in ids: [String]) async throws -> Set<String> {
        batches.append(ids)
        if let failure { throw failure }
        return known.intersection(ids)
    }

    func insert(_: DownloadHistoryRecord) async throws {
        Issue.record("the paste hint must never write history")
    }

    func entries(
        before _: PageCursor<Double>?,
        limit _: Int
    ) async throws -> Page<DownloadHistoryRecord, Double> {
        Issue.record("the paste hint must never page history")
        return Page(items: [], nextCursor: nil)
    }

    func delete(id _: String) async throws -> Bool {
        Issue.record("the paste hint must never delete history")
        return false
    }

    func deleteAll() async throws -> Int {
        Issue.record("the paste hint must never clear history")
        return 0
    }

    func latestEntry(canonicalVideoID _: String) async throws -> DownloadHistoryRecord? {
        Issue.record("the paste hint must use the BATCH lookup, never a per-id one")
        return nil
    }
}

/// A ``DownloadQueueing`` decorator that keeps every ``EnqueueOutcome`` its inner queue
/// produced.
///
/// The view model maps an outcome into `DownloadPasteReport` on the way out, so
/// comparing reports would compare a projection. This keeps the outcome VALUE the queue
/// returned, which is what the acceptance criterion is written about.
@MainActor
private final class OutcomeRecordingQueue: DownloadQueueing {
    let inner: FakeDownloadQueue
    private(set) var outcomes: [EnqueueOutcome] = []

    init(_ inner: FakeDownloadQueue = FakeDownloadQueue()) {
        self.inner = inner
    }

    var onQueueChanged: (@Sendable (DownloadQueueSnapshot) -> Void)? {
        get { inner.onQueueChanged }
        set { inner.onQueueChanged = newValue }
    }

    var onItemProgress: (@Sendable (UUID, DownloadState) -> Void)? {
        get { inner.onItemProgress }
        set { inner.onItemProgress = newValue }
    }

    func enqueue(urls: [URL]) async -> EnqueueOutcome {
        let outcome = await inner.enqueue(urls: urls)
        outcomes.append(outcome)
        return outcome
    }

    func confirmPlaylist(_ pendingToken: UUID) async -> EnqueueOutcome {
        let outcome = await inner.confirmPlaylist(pendingToken)
        outcomes.append(outcome)
        return outcome
    }

    func cancelCurrent() {
        inner.cancelCurrent()
    }

    func cancel(itemID: UUID) {
        inner.cancel(itemID: itemID)
    }

    func removePending(_ id: UUID) {
        inner.removePending(id)
    }

    func movePending(_ id: UUID, to index: Int) {
        inner.movePending(id, to: index)
    }

    func pause() {
        inner.pause()
    }

    func resume() {
        inner.resume()
    }

    func cancelAll() {
        inner.cancelAll()
    }
}

/// Queue + store + model, wired the way the composition root wires them.
///
/// The store is fed from `onQueueChanged` exactly as `connectDownloadsUI` feeds it, so
/// `model.count` really is the queue's membership: without that wiring the projection
/// reports zero however the queue behaved, and "the video was still enqueued" could not
/// be asserted at all.
@MainActor
private final class HintHarness {
    /// The seam's monotonic counter, boxed so the closure can own it.
    ///
    /// The counter deliberately does NOT live on the harness: a closure capturing the
    /// harness weakly stops ingesting the moment a test writes `harness.model` and lets
    /// the harness go, which makes `model.count` report zero for a queue that really did
    /// accept rows — the "measures nothing" shape again, from a lifetime rather than a
    /// seam. Owning the box and the store keeps the wiring alive as long as the model is.
    @MainActor
    private final class SequenceBox {
        var value = 0
    }

    let queue = OutcomeRecordingQueue()
    let store = DownloadQueueStore()
    let model: DownloadsViewModel

    init(history: (any DownloadHistoryRepositoryProviding)?) {
        model = DownloadsViewModel(queue: queue, store: store, history: history)
        let store = store
        let sequence = SequenceBox()
        queue.onQueueChanged = { snapshot in
            MainActor.assumeIsolated {
                sequence.value += 1
                store.ingest(sequence: sequence.value, snapshot: snapshot)
            }
        }
    }
}

// MARK: - Tests

@MainActor
struct DownloadsPasteHistoryHintTests {
    private static let videoIDs = [
        "dQw4w9WgXcQ", "9bZkp7q19f0", "SkVqJ1SGeL0", "Y-rmzh0PI3c", "WhWc3b3KhnY",
    ]
    private static let playlistLink = "https://www.youtube.com/playlist?list=PLabcdefghijk"

    private static func watchLine(_ videoID: String) -> String {
        "https://www.youtube.com/watch?v=\(videoID)"
    }

    private static func watchURL(_ videoID: String) -> URL {
        URL(string: watchLine(videoID)) ?? URL(fileURLWithPath: videoID)
    }

    private static func paste(_ videoIDs: [String]) -> String {
        videoIDs.map(watchLine).joined(separator: "\n")
    }

    /// Distinct, well-formed 11-character ids — the same shape the paste-flow suite uses
    /// for over-cap fixtures.
    private static func syntheticIDs(_ count: Int) -> [String] {
        (0 ..< count).map { String(format: "v%010d", $0) }
    }

    private static func harness(
        history: (any DownloadHistoryRepositoryProviding)?
    ) -> HintHarness {
        HintHarness(history: history)
    }

    // MARK: The count

    /// Acceptance: two of the pasted links have been downloaded before, out of five —
    /// the hint reports 2, not 5 and not 0.
    @Test func twoKnownIDsInALargerPasteReportExactlyTwo() async {
        let history = RecordingDownloadHistory(known: ["SkVqJ1SGeL0", "Y-rmzh0PI3c"])
        let model = Self.harness(history: history).model
        let urls = Self.videoIDs.map(Self.watchURL)

        _ = await model.submit(pastedText: Self.paste(Self.videoIDs))
        let count = await model.previouslyDownloadedCount(in: urls)

        #expect(count == 2)
        #expect(history.batches.count == 1)
    }

    /// Acceptance: an empty log answers zero, which the sheet renders as NO line — never
    /// as "0 of these".
    @Test func anEmptyHistoryProducesNoHintAtAll() async {
        let history = RecordingDownloadHistory()
        let model = Self.harness(history: history).model

        let count = await model.previouslyDownloadedCount(in: Self.videoIDs.map(Self.watchURL))

        #expect(count == 0)
        #expect(history.batches.count == 1, "the log really was consulted and really answered nothing")
    }

    /// Acceptance: a throwing repository is suppressed — no error surfaces, the count is
    /// zero, and the paste that preceded it stands exactly as it would have without any
    /// history at all.
    @Test func aThrowingRepositoryIsSuppressedAndThePasteStandsUntouched() async {
        let history = RecordingDownloadHistory(failure: CocoaError(.fileReadUnknown))
        let failingHarness = Self.harness(history: history)
        let noneHarness = Self.harness(history: nil)
        let failing = failingHarness.model
        let none = noneHarness.model
        let text = Self.paste(Self.videoIDs)

        let failingResult = await failing.submit(pastedText: text)
        let count = await failing.previouslyDownloadedCount(in: Self.videoIDs.map(Self.watchURL))
        let controlResult = await none.submit(pastedText: text)

        #expect(count == 0)
        #expect(history.batches.count == 1, "the throw happened INSIDE the lookup, not before it")
        #expect(failingResult == controlResult)
        #expect(failing.count == none.count)
        #expect(failing.count == Self.videoIDs.count)
    }

    // MARK: The invariant

    /// THE load-bearing test. One identical paste, two models — one whose history log
    /// answers with matches, one with no log at all — and the `EnqueueOutcome` the queue
    /// returned must be equal field for field.
    ///
    /// `#expect(hinted.batches.count == 1)` is what stops this passing vacuously: without
    /// it, a build in which the hint never runs satisfies the equality perfectly.
    @Test func theEnqueueOutcomeIsByteIdenticalWithAndWithoutTheHint() async {
        let hinted = RecordingDownloadHistory(known: Set(Self.videoIDs))
        let hintedQueue = OutcomeRecordingQueue()
        let hintedModel = DownloadsViewModel(
            queue: hintedQueue, store: DownloadQueueStore(), history: hinted
        )
        let plainQueue = OutcomeRecordingQueue()
        let plainModel = DownloadsViewModel(
            queue: plainQueue, store: DownloadQueueStore(), history: nil
        )
        let text = Self.paste(Self.videoIDs + [Self.videoIDs[0]])
        let urls = DownloadPasteInput.parse(text).urls

        let hintedResult = await hintedModel.submit(pastedText: text)
        let hintedCount = await hintedModel.previouslyDownloadedCount(in: urls)
        let plainResult = await plainModel.submit(pastedText: text)
        let plainCount = await plainModel.previouslyDownloadedCount(in: urls)

        #expect(hintedQueue.outcomes == plainQueue.outcomes)
        #expect(hintedQueue.outcomes == [EnqueueOutcome(added: 5, duplicatesDropped: 1)])
        #expect(hintedResult == plainResult)
        #expect(hinted.batches.count == 1, "or the equality above is comparing two runs of the same program")
        #expect(hintedCount == 5)
        #expect(plainCount == 0)
    }

    /// Advisory means advisory: a video downloaded before is still enqueued.
    @Test func aPreviouslyDownloadedVideoIsStillQueued() async {
        let history = RecordingDownloadHistory(known: Set(Self.videoIDs))
        let model = Self.harness(history: history).model

        let result = await model.submit(pastedText: Self.paste(Self.videoIDs))
        let count = await model.previouslyDownloadedCount(in: Self.videoIDs.map(Self.watchURL))

        #expect(count == Self.videoIDs.count)
        #expect(result.report.added == Self.videoIDs.count)
        #expect(result.report.duplicatesDropped == 0)
        #expect(model.count == Self.videoIDs.count)
    }

    // MARK: The shape of the question

    /// ONE batch, never a lookup per id, and never more than the call-site ceiling —
    /// asked about the FIRST ids in paste order so a truncated question is deterministic.
    @Test func theLookupIsOneBatchOfAtMostFiftyIDsInPasteOrder() async {
        let limit = DownloadsViewModel.previouslyDownloadedLookupLimit
        let ids = Self.syntheticIDs(limit + 10)
        let history = RecordingDownloadHistory()
        let model = Self.harness(history: history).model

        _ = await model.previouslyDownloadedCount(in: ids.map(Self.watchURL))

        #expect(history.batches.count == 1)
        #expect(history.batches.first?.count == limit)
        #expect(history.batches.first == Array(ids.prefix(limit)))
        #expect(limit <= DownloadHistoryRepository.videoIDLookupLimit)
    }

    /// Repeated links cost one slot in the batch, not two — the question is deduplicated
    /// in paste order before it is asked.
    @Test func duplicateLinksAreAskedAboutOnce() async {
        let history = RecordingDownloadHistory(known: [Self.videoIDs[0]])
        let model = Self.harness(history: history).model
        let urls = [Self.videoIDs[0], Self.videoIDs[1], Self.videoIDs[0]].map(Self.watchURL)

        let count = await model.previouslyDownloadedCount(in: urls)

        #expect(count == 1)
        #expect(history.batches == [[Self.videoIDs[0], Self.videoIDs[1]]])
    }

    /// A paste that names no video asks nothing at all — a playlist link carries no
    /// canonical id, and an empty batch is a statement the log never has to answer.
    @Test func aPasteThatNamesNoVideoAsksNothing() async throws {
        let history = RecordingDownloadHistory()
        let model = Self.harness(history: history).model
        let playlist = try #require(URL(string: Self.playlistLink))

        let count = await model.previouslyDownloadedCount(in: [playlist])

        #expect(count == 0)
        #expect(history.batches.isEmpty)
    }

    /// The same suppression, against a REAL `DownloadHistoryRepository` over a REAL
    /// GRDB database that has no `downloadHistory` table.
    ///
    /// The fake-throw test above proves the view model swallows an error; this proves it
    /// swallows the error GRDB itself raises, through the shipped repository, with no
    /// double in the path. A live database can fail in ways a fake is not written to
    /// imitate, and the hint's whole contract is that none of them reach the listener.
    @Test func aRealDatabaseErrorIsSwallowedByTheHint() async throws {
        let repository = try DownloadHistoryRepository(DatabaseQueue())
        let harness = HintHarness(history: repository)
        let text = Self.paste(Self.videoIDs)

        let result = await harness.model.submit(pastedText: text)
        let count = await harness.model.previouslyDownloadedCount(in: Self.videoIDs.map(Self.watchURL))

        await #expect(throws: (any Error).self) {
            _ = try await repository.knownVideoIDs(in: Self.videoIDs)
        }
        #expect(count == 0)
        #expect(result.report.added == Self.videoIDs.count)
        #expect(harness.model.count == Self.videoIDs.count)
    }

    /// With no log injected — every non-macOS shell, and every queue-only test — the
    /// hint is absent rather than zero-cost-but-present.
    @Test func withoutAHistoryLogNothingIsLookedUpAtAll() async {
        let model = Self.harness(history: nil).model

        let count = await model.previouslyDownloadedCount(in: Self.videoIDs.map(Self.watchURL))

        #expect(count == 0)
    }
}
