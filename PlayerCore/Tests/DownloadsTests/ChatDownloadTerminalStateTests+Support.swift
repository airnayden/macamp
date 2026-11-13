// The end-to-end rig for the terminal-state handler: a REAL ``FakeDownloadQueue`` whose
// own seams feed a real ``DownloadItemVideoIDMap``, a real ``SuggestionDownloadRegistry``,
// and the real ``ChatDownloadPlaylistAppender`` over a real migrated in-memory database.
//
// ── NOTHING IS HAND-FED ──────────────────────────────────────────────────────
//
// The UUID a test drives a terminal state with is the one the QUEUE minted, and the map
// learns about it only through `onQueueChanged`. That is the point of driving through the
// double rather than calling `handler.handle(itemID:state:)` with a pair the test made up:
// the correlation itself — the thing that would silently resolve nothing in production if
// `ingest` ever started mirroring instead of accumulating — is under test.
//
// ── COMPOSED, NOT FORKED ─────────────────────────────────────────────────────
//
// ``ChatDownloadAppenderFixture`` (todo 4) is HELD, not copied: the counting scanner, the
// announcement log, the gate boxes and the real repositories all come from it unchanged,
// so `scanLog.count == 0` means here exactly what it means there. That file is landed and
// is not modified by this one.
//
// ── THE CHAIN ────────────────────────────────────────────────────────────────
//
// `onItemProgress` is a synchronous `@Sendable` seam and `handle(itemID:state:)` is
// `async`, so each emission is queued behind its predecessor and ``drain()`` waits on the
// tail. That is the same shape todo 9 will install, and it is what makes an assertion
// written straight after `emitProgress` deterministic instead of racy.
//
// Names are prefixed `ChatTerminal…` because the whole `DownloadsTests` target shares one
// namespace.
import Foundation
import Persistence
import PlayerCoreTestSupport
import Services
import Testing

enum ChatTerminalFixtureError: Error {
    case notEnqueued(String)
    case notStarted(String)
}

/// Canonical video ids the terminal-state suites drive. Eleven characters each, so the
/// real ``YouTubeURLNormalizer`` accepts the watch URLs built from them.
enum ChatTerminalFixtureIDs {
    static let first = "dQw4w9WgXcQ"
    static let second = "9bZkp7q19f0"
}

/// The assembled queue → map → handler → appender pipeline plus every seam a test needs.
@MainActor
final class ChatTerminalFixture {
    let appenderFixture: ChatDownloadAppenderFixture
    let queue = FakeDownloadQueue()
    let map = DownloadItemVideoIDMap()
    let history: DownloadHistoryRepository

    /// The tail of the progress chain, so ``drain()`` can wait for every queued emission.
    private var chain: Task<Void, Never>?

    private(set) lazy var handler = ChatDownloadTerminalStateHandler(
        registry: appenderFixture.registry,
        map: map,
        appender: appenderFixture.appender,
        historyFilePath: { [history] videoID in
            let entry = try? await history.latestEntry(canonicalVideoID: videoID)
            return entry?.filePath
        },
        announce: { [appenderFixture] event in appenderFixture.announcements.record(event) }
    )

    init() throws {
        let fixture = try ChatDownloadAppenderFixture()
        appenderFixture = fixture
        history = DownloadHistoryRepository(fixture.database)
        installSeams()
    }

    // MARK: - Pass-throughs

    var registry: SuggestionDownloadRegistry {
        appenderFixture.registry
    }

    var announcements: ChatAppendAnnouncementLog {
        appenderFixture.announcements
    }

    var scanLog: ChatAppendScanLog {
        appenderFixture.scanLog
    }

    var destination: URL {
        appenderFixture.destination
    }

    func cleanUp() {
        chain?.cancel()
        appenderFixture.cleanUp()
    }

    // MARK: - Driving the queue

    /// Enqueues `videoID` and leaves it pending, returning the row the QUEUE minted —
    /// the only place a test learns an item id from.
    @discardableResult
    func enqueuePending(_ videoID: String) async throws -> DownloadItem {
        let url = try downloadTestURL("https://www.youtube.com/watch?v=\(videoID)")
        let outcome = await queue.enqueue(urls: [url])
        guard outcome.added == 1 else { throw ChatTerminalFixtureError.notEnqueued(videoID) }
        guard let item = queue.pendingItems.first(where: { $0.canonicalVideoID == videoID }) else {
            throw ChatTerminalFixtureError.notEnqueued(videoID)
        }
        await drain()
        return item
    }

    /// Enqueues `videoID` and hands it to the driver, so the row is in flight.
    @discardableResult
    func startDownload(_ videoID: String) async throws -> DownloadItem {
        let pending = try await enqueuePending(videoID)
        queue.startNext()
        guard let item = queue.activeItems.first(where: { $0.id == pending.id }) else {
            throw ChatTerminalFixtureError.notStarted(videoID)
        }
        await drain()
        return item
    }

    /// Publishes a terminal state the way the production driver's `settle(_:)` does —
    /// row out, item state, then the snapshot — and waits for the handler.
    func finish(_ item: DownloadItem, state: DownloadState) async {
        queue.finish(id: item.id, state: state)
        await drain()
    }

    /// Publishes a state WITHOUT retiring the row, for the non-terminal cases and for the
    /// ordering-inversion test where the row has already left the queue.
    func emit(_ itemID: UUID, state: DownloadState) async {
        queue.emitProgress(id: itemID, state: state)
        await drain()
    }

    /// Waits for every queued `onItemProgress` handling to finish.
    func drain() async {
        await chain?.value
    }

    // MARK: - Seeding

    @discardableResult
    func register(_ videoID: String, playlistId: Int64) -> Bool {
        registry.register(videoID: videoID, target: .playlist(playlistId), profileId: ProfileRecord.guestID)
    }

    /// Appends one `downloadHistory` row naming `filePath`, the way
    /// ``DownloadHistoryRecorder`` does when a download completes.
    func recordHistory(videoID: String, filePath: String) async throws {
        try await history.insert(DownloadHistoryRecord(
            id: UUID().uuidString,
            canonicalVideoID: videoID,
            title: "Recovered",
            filePath: filePath,
            audioFormat: "m4a",
            audioQuality: "best",
            sourceURL: "https://www.youtube.com/watch?v=\(videoID)",
            downloadedAt: 1_700_000_000,
            utcOffsetSeconds: 0
        ))
    }

    /// A path in the (non-root) destination folder, with a real library row behind it —
    /// "the history row's file IS in the library".
    @discardableResult
    func importedFilePath(named name: String = "Recovered [dQw4w9WgXcQ].m4a") throws -> (path: String, trackId: Int64) {
        let file = try appenderFixture.writeDownloadedFile(named: name)
        let trackId = try appenderFixture.insertTrack(at: file.path)
        return (file.path, trackId)
    }

    @discardableResult
    func makePlaylist(named name: String) throws -> Int64 {
        try appenderFixture.makePlaylist(named: name)
    }

    func membership(playlistId: Int64) async throws -> [Int64] {
        try await appenderFixture.membership(playlistId: playlistId)
    }

    // MARK: - Internals

    /// Chains the map onto `onQueueChanged` and the handler onto `onItemProgress`, the
    /// way todo 9 will chain them onto the shipped queue.
    private func installSeams() {
        queue.onQueueChanged = { [map] snapshot in
            MainActor.assumeIsolated { map.ingest(snapshot) }
        }
        queue.onItemProgress = { [weak self] id, state in
            MainActor.assumeIsolated { self?.handle(itemID: id, state: state) }
        }
    }

    private func handle(itemID: UUID, state: DownloadState) {
        let previous = chain
        let handler = handler
        chain = Task {
            await previous?.value
            await handler.handle(itemID: itemID, state: state)
        }
    }
}
