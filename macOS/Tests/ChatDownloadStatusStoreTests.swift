// ChatDownloadStatusStoreTests — the projection is total, keyed both ways, and never
// sticky.
//
// Three properties are worth more than the rest and are locked first:
//
//   * TOTALITY — every `DownloadState` shape and all twelve `ChatDownloadAppendEvent`
//     cases are driven through as tables. A status column that silently keeps saying
//     "Downloading" because one case fell through is indistinguishable from a hung
//     download, and it is the one failure a listener cannot diagnose.
//   * ALIASING — a status written before the resolve is readable through the video id
//     after it, AND every queue event that arrives afterwards (addressed by the video
//     id, the only name the queue knows) is readable through the candidate key the
//     table is still rendering. Both directions, because the table and the queue each
//     hold exactly one of the two keys and neither can be asked to learn the other.
//   * NOT STICKY — `.downloaded` is overwritten by a later `.queued`, or a second
//     download of the same song would render as already finished before it started.
//
// The playlist-name closure is injected (a dictionary here, an off-main repository read
// in production) so `.addedToPlaylist` is assertable without a database.
import Foundation
@testable import MacAMP
import Services
import Testing

@Suite("Chat download status store")
@MainActor
struct ChatDownloadStatusStoreTests {
    // MARK: - Totality

    /// Every `DownloadState` shape, including both ends of the post-processing
    /// fraction. `.fetchingMetadata` reports `nil` rather than a fabricated 0.
    @Test(
        "every download state maps to exactly one row status",
        arguments: [
            (DownloadState.queued, ChatDownloadRowStatus.queued),
            (.fetchingMetadata, .downloading(fraction: nil)),
            (.downloading(fraction: 0.42, speedBytesPerSec: nil, etaSeconds: nil), .downloading(fraction: 0.42)),
            (.postProcessing(fraction: nil), .converting),
            (.postProcessing(fraction: 0.5), .converting),
            (.finished(fileURL: Fixtures.fileURL), .downloaded),
            (.failed(.downloadFailed(detail: nil)), .failed),
            (.cancelled, .none),
        ]
    )
    func everyDownloadStateMaps(state: DownloadState, expected: ChatDownloadRowStatus) {
        #expect(ChatDownloadStatusPolicy.status(for: state) == expected)
    }

    /// All twelve cases of the frozen append vocabulary. A thirteenth would break the
    /// policy's own build; this table proves the twelve that exist say the right thing.
    @Test(
        "every append event maps to exactly one effect",
        arguments: [
            (
                ChatDownloadAppendEvent.appended(playlistId: 7, trackId: 1),
                ChatDownloadStatusEffect.addedToPlaylist(playlistId: 7)
            ),
            (.gateFailed, .set(.downloaded)),
            (.importFailed, .set(.failed)),
            (.playlistMissing(4), .set(.failed)),
            (.appendFailed(4), .set(.failed)),
            (.alreadyDownloadedUnresolved, .set(.failed)),
            (.appendAbandoned, .set(.failed)),
            (.heldForProposal(Fixtures.proposalID), .unchanged),
            (.alreadyInPlaylist(playlistId: 1, trackId: 2), .unchanged),
            (.queueFull(count: 64), .unchanged),
            (.notRegisteredNoPlaylist, .unchanged),
            (.skippedProfileChanged, .unchanged),
        ]
    )
    func everyAppendEventMaps(event: ChatDownloadAppendEvent, expected: ChatDownloadStatusEffect) {
        #expect(ChatDownloadStatusPolicy.effect(for: event) == expected)
    }

    @Test("an unknown key says nothing at all")
    func anUnknownKeySaysNothing() {
        #expect(Fixtures.store().status(for: "dQw4w9WgXcQ") == .none)
    }

    // MARK: - Queue feeds

    @Test("a snapshot's pending rows are queued and its active rows report their phase")
    func aSnapshotFeedsBothHalves() {
        let store = Fixtures.store()

        store.ingest(DownloadQueueSnapshot(
            activeItems: [Fixtures.item("aaaaaaaaaaa", state: Fixtures.downloading(0.25))],
            pendingItems: [Fixtures.item("bbbbbbbbbbb"), Fixtures.item("ccccccccccc")],
            isPaused: false
        ))

        #expect(store.status(for: "aaaaaaaaaaa") == .downloading(fraction: 0.25))
        #expect(store.status(for: "bbbbbbbbbbb") == .queued)
        #expect(store.status(for: "ccccccccccc") == .queued)
    }

    /// A finished row leaves the queue immediately, so an `ingest` that mirrored the
    /// snapshot would erase `.downloaded` the instant it became true.
    @Test("a row absent from a later snapshot keeps the status it had")
    func ingestIsAdditive() {
        let store = Fixtures.store()

        store.ingest(DownloadQueueSnapshot(
            activeItems: [],
            pendingItems: [Fixtures.item("aaaaaaaaaaa")],
            isPaused: false
        ))
        store.ingest(.empty)

        #expect(store.status(for: "aaaaaaaaaaa") == .queued)
    }

    @Test("a progress sample resolves its item id through the injected map")
    func aProgressSampleResolvesThroughTheMap() {
        let store = Fixtures.store()
        let itemID = UUID()

        store.apply(itemID: itemID, state: Fixtures.downloading(0.6), videoID: { _ in "aaaaaaaaaaa" })

        #expect(store.status(for: "aaaaaaaaaaa") == .downloading(fraction: 0.6))
    }

    @Test("a progress sample for an unmappable item id changes nothing")
    func anUnmappableSampleIsDropped() {
        let store = Fixtures.store()

        store.apply(itemID: UUID(), state: .queued, videoID: { _ in nil })

        #expect(store.status(for: "aaaaaaaaaaa") == .none)
    }

    /// THE RETENTION CONTRACT. `DownloadItemVideoIDMap` accumulates and is pruned only
    /// by the terminal handler AFTER it has resolved the id — so a terminal state that
    /// arrives once the row has already left the queue still lands on the right row.
    /// The map double here keeps answering exactly as the real one does.
    @Test("a terminal state for a row absent from the latest snapshot still lands")
    func aTerminalStateAfterTheRowLeftTheSnapshotStillLands() {
        let store = Fixtures.store()
        let itemID = UUID()
        let item = Fixtures.item("aaaaaaaaaaa", id: itemID, state: Fixtures.downloading(0.9))

        store.ingest(DownloadQueueSnapshot(activeItems: [item], pendingItems: [], isPaused: false))
        store.ingest(.empty)
        store.apply(
            itemID: itemID,
            state: .finished(fileURL: Fixtures.fileURL),
            videoID: { $0 == itemID ? "aaaaaaaaaaa" : nil }
        )

        #expect(store.status(for: "aaaaaaaaaaa") == .downloaded)
    }

    @Test("a cancelled row goes back to saying nothing")
    func aCancelledRowGoesBackToNothing() {
        let store = Fixtures.store()
        let itemID = UUID()

        store.apply(itemID: itemID, state: .queued, videoID: { _ in "aaaaaaaaaaa" })
        store.apply(itemID: itemID, state: .cancelled, videoID: { _ in "aaaaaaaaaaa" })

        #expect(store.status(for: "aaaaaaaaaaa") == .none)
    }

    // MARK: - Append feeds

    @Test("an append names the playlist it landed in")
    func anAppendNamesThePlaylist() async {
        let store = Fixtures.store(names: [7: "Late Night"])

        await store.apply(.appended(playlistId: 7, trackId: 1), videoID: "aaaaaaaaaaa")

        #expect(store.status(for: "aaaaaaaaaaa") == .addedToPlaylist(name: "Late Night"))
    }

    /// The rendering side owns the fallback copy, exactly as the toast coalescer does.
    @Test("an unreadable playlist name lands as an empty name, not a failure")
    func anUnreadableNameLandsEmpty() async {
        let store = Fixtures.store()

        await store.apply(.appended(playlistId: 9, trackId: 1), videoID: "aaaaaaaaaaa")

        #expect(store.status(for: "aaaaaaaaaaa") == .addedToPlaylist(name: ""))
    }

    /// The import gate refused the file, so no scan ran — but the download itself
    /// succeeded, and that is what this row reports.
    @Test("a refused import still reports the download as downloaded")
    func aRefusedImportStillReportsDownloaded() async {
        let store = Fixtures.store()

        await store.apply(.gateFailed, videoID: "aaaaaaaaaaa")

        #expect(store.status(for: "aaaaaaaaaaa") == .downloaded)
    }

    /// The playlist link failed; the file is on disk, and `.downloaded` remains the true
    /// report of what happened to this row.
    @Test("the five link-only failures leave the row's own status alone")
    func linkOnlyFailuresLeaveTheRowAlone() async {
        let store = Fixtures.store()
        let unchanged: [ChatDownloadAppendEvent] = [
            .heldForProposal(Fixtures.proposalID),
            .alreadyInPlaylist(playlistId: 1, trackId: 2),
            .queueFull(count: 64),
            .notRegisteredNoPlaylist,
            .skippedProfileChanged,
        ]

        await store.apply(.gateFailed, videoID: "aaaaaaaaaaa")
        for event in unchanged {
            await store.apply(event, videoID: "aaaaaaaaaaa")
            #expect(store.status(for: "aaaaaaaaaaa") == .downloaded)
        }
    }

    @Test("an append with no video id changes nothing")
    func anAppendWithNoVideoIDChangesNothing() async {
        let store = Fixtures.store(names: [7: "Late Night"])

        await store.apply(.appended(playlistId: 7, trackId: 1), videoID: nil)

        #expect(store.status(for: "aaaaaaaaaaa") == .none)
    }

    // MARK: - Aliasing

    @Test("a status written before the resolve is readable through the video id after it")
    func theCandidatesStatusSurvivesTheBind() {
        let store = Fixtures.store()

        store.markResolving(candidateKey: Fixtures.candidate)
        store.bind(candidateKey: Fixtures.candidate, toVideoID: "aaaaaaaaaaa")

        #expect(store.status(for: "aaaaaaaaaaa") == .resolving)
        #expect(store.status(for: Fixtures.candidate) == .resolving)
    }

    @Test("a queue event addressed by the video id is readable through the candidate key")
    func aQueueEventReachesTheCandidateRow() {
        let store = Fixtures.store()

        store.markResolving(candidateKey: Fixtures.candidate)
        store.bind(candidateKey: Fixtures.candidate, toVideoID: "aaaaaaaaaaa")
        store.ingest(DownloadQueueSnapshot(
            activeItems: [],
            pendingItems: [Fixtures.item("aaaaaaaaaaa")],
            isPaused: false
        ))

        #expect(store.status(for: Fixtures.candidate) == .queued)
        #expect(store.status(for: "aaaaaaaaaaa") == .queued)
    }

    /// A verified row and a candidate that resolved to the same video are the same
    /// download — the one already in flight is the true report.
    @Test("binding onto a video id that is already in flight keeps the live status")
    func theInFlightStatusWinsTheBind() {
        let store = Fixtures.store()

        store.ingest(DownloadQueueSnapshot(
            activeItems: [Fixtures.item("aaaaaaaaaaa", state: Fixtures.downloading(0.3))],
            pendingItems: [],
            isPaused: false
        ))
        store.markResolving(candidateKey: Fixtures.candidate)
        store.bind(candidateKey: Fixtures.candidate, toVideoID: "aaaaaaaaaaa")

        #expect(store.status(for: Fixtures.candidate) == .downloading(fraction: 0.3))
    }

    @Test("a candidate that resolved to nothing says not found")
    func anUnresolvableCandidateSaysNotFound() {
        let store = Fixtures.store()

        store.markResolving(candidateKey: Fixtures.candidate)
        store.markNotFound(candidateKey: Fixtures.candidate)

        #expect(store.status(for: Fixtures.candidate) == .notFound)
    }

    // MARK: - History priming

    @Test("history marks videos nothing else has claimed")
    func historyMarksUnclaimedRows() {
        let store = Fixtures.store()

        store.markKnown(videoIDs: ["aaaaaaaaaaa", "bbbbbbbbbbb"])

        #expect(store.status(for: "aaaaaaaaaaa") == .alreadyDownloaded)
        #expect(store.status(for: "bbbbbbbbbbb") == .alreadyDownloaded)
    }

    /// The history read hops off the main actor, so its answer can land after the
    /// listener has already pressed Download. It must not overwrite a live row.
    @Test("history never overrides a row that is already doing something")
    func historyNeverOverridesAnInFlightRow() {
        let store = Fixtures.store()

        store.ingest(DownloadQueueSnapshot(
            activeItems: [Fixtures.item("bbbbbbbbbbb", state: Fixtures.downloading(0.4))],
            pendingItems: [Fixtures.item("aaaaaaaaaaa")],
            isPaused: false
        ))
        store.markKnown(videoIDs: ["aaaaaaaaaaa", "bbbbbbbbbbb"])

        #expect(store.status(for: "aaaaaaaaaaa") == .queued)
        #expect(store.status(for: "bbbbbbbbbbb") == .downloading(fraction: 0.4))
    }

    // MARK: - Not sticky

    @Test("downloading the same song again reads as queued, not as already finished")
    func aReDownloadReadsAsQueued() {
        let store = Fixtures.store()
        let itemID = UUID()

        store.apply(itemID: itemID, state: .finished(fileURL: Fixtures.fileURL), videoID: { _ in "aaaaaaaaaaa" })
        #expect(store.status(for: "aaaaaaaaaaa") == .downloaded)

        store.ingest(DownloadQueueSnapshot(
            activeItems: [],
            pendingItems: [Fixtures.item("aaaaaaaaaaa")],
            isPaused: false
        ))

        #expect(store.status(for: "aaaaaaaaaaa") == .queued)
    }

    @Test("a re-download after an already-downloaded hint reads as queued too")
    func aReDownloadOverridesTheHistoryHint() {
        let store = Fixtures.store()

        store.markKnown(videoIDs: ["aaaaaaaaaaa"])
        store.ingest(DownloadQueueSnapshot(
            activeItems: [],
            pendingItems: [Fixtures.item("aaaaaaaaaaa")],
            isPaused: false
        ))

        #expect(store.status(for: "aaaaaaaaaaa") == .queued)
    }

    @Test("resetting forgets every row and every alias")
    func resettingForgetsEverything() {
        let store = Fixtures.store()

        store.markResolving(candidateKey: Fixtures.candidate)
        store.bind(candidateKey: Fixtures.candidate, toVideoID: "aaaaaaaaaaa")
        store.removeAll()

        #expect(store.status(for: Fixtures.candidate) == .none)
        #expect(store.status(for: "aaaaaaaaaaa") == .none)

        // The alias is gone too, so the candidate key is its own row again.
        store.markNotFound(candidateKey: Fixtures.candidate)
        #expect(store.status(for: "aaaaaaaaaaa") == .none)
    }
}

/// Shared fixtures, deliberately OUTSIDE the `@MainActor` suite.
///
/// `@Test(arguments:)` expands its argument expressions into a context that is not
/// main-actor-isolated, so a `static let` declared inside the suite is unreachable from
/// there (`main actor-isolated static property … cannot be accessed from outside of the
/// actor`, reported against generated `@__swiftmacro_…` source rather than the fixture).
/// Living out here keeps them readable from both the tables and the test bodies.
private enum Fixtures {
    static let candidate = "q:tokyodrift|teriyaki boyz"
    static let proposalID = UUID()
    static let fileURL = URL(fileURLWithPath: "/tmp/macamp-status-store.m4a")

    @MainActor
    static func store(names: [Int64: String] = [:]) -> ChatDownloadStatusStore {
        ChatDownloadStatusStore(playlistName: { names[$0] })
    }

    static func downloading(_ fraction: Double) -> DownloadState {
        .downloading(fraction: fraction, speedBytesPerSec: nil, etaSeconds: nil)
    }

    static func item(
        _ videoID: String,
        id: UUID = UUID(),
        state: DownloadState = .queued
    ) -> DownloadItem {
        DownloadItem(
            id: id,
            canonicalVideoID: videoID,
            sourceURL: URL(string: "https://www.youtube.com/watch?v=\(videoID)")
                ?? URL(fileURLWithPath: videoID),
            state: state
        )
    }
}
