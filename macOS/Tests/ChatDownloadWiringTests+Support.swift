// The rig for the chat-download composition suites: a REAL `AppEnvironment` whose
// download graph is built by the SHIPPED entry point, `connectDownloads(settings:)`.
//
// ── WHY THE PUBLIC ENTRY POINT, AND NOT A HAND-ASSEMBLED GRAPH ───────────────
//
// Everything this suite is about is INSTALLATION ORDER: the route is handed to
// `wireDownloadSeams` rather than chained after it, the video-id map is chained onto
// `onQueueChanged` after the downloads pane's own projection, the terminal handler is
// chained onto `onItemProgress`. A test that built the pieces itself would assert the
// pieces, which `PlayerCore`'s own suites already do, and would keep passing after the
// wiring stopped installing them. So the harness calls `connectDownloads(settings:)` and
// then fires the queue's OWN seam properties — the closures production installed.
//
// ── AND WHY THE QUEUE IS SWAPPED FOR A DOUBLE AFTERWARDS ─────────────────────
//
// `connectDownloads` builds a real `DownloadQueueService` over a real
// `YtDlpProcessRunner` and a real `YouTubeOEmbedClient`. Enqueuing through it would
// `pump()` a yt-dlp child and fire an oEmbed request per row — a unit suite must do
// neither. `AppEnvironment.downloads` is a `public var`, so the harness points it at a
// scripted ``ChatDownloadQueueDouble`` for the ENQUEUE half while keeping a reference to
// the real service for the SEAM half. Both halves therefore run production code: the
// real installed closures on one side, the real `handleChatDownloadRequest` on the other.
//
// The queue-depth cap is expressed as the outcome the real service REPORTS for it —
// `added: 0, duplicatesDropped: 0` — because `DownloadQueueService.append` breaks out at
// `maxQueueDepth` and its own doc states a cap-refused row "is NOT a duplicate and is not
// reported as one". Pre-filling 1000 real rows would buy the same `EnqueueOutcome` at the
// cost of 1000 network decorations.
import Artwork
import AudioEngine
import DSP
import Foundation
import Lyrics
@testable import MacAMP
import Metadata
import Persistence
import Services
import Testing
import ViewModels

enum ChatDownloadFixtureError: Error {
    case queueUnavailable
    case appenderUnavailable
}

/// Canonical ids the suites drive. Eleven characters each, so the real
/// `YouTubeURLNormalizer` builds watch URLs from them.
enum ChatDownloadFixtureIDs {
    static let first = "dQw4w9WgXcQ"
    static let second = "9bZkp7q19f0"
}

// MARK: - Doubles

/// Counts `.files` scans without touching the filesystem, and reports a summary that
/// WOULD earn the legacy "added to your library" toast.
///
/// The non-empty summary is load-bearing: with `ScanSummary()` the legacy path decides
/// `announces == false` on its own and the suppression assertion passes vacuously.
/// `LaunchSequenceTests.CountingScanner` is `private` to that file and counts `.directory`
/// requests, so this is its own type rather than a shared one.
final class ChatDownloadCountingScanner: LibraryScanning, @unchecked Sendable {
    private let lock = NSLock()
    private var files = 0

    var fileScanCount: Int {
        lock.withLock { files }
    }

    func events(for request: ScanRequest) -> AsyncStream<ScanEvent> {
        let summary = record(request)
        return AsyncStream { continuation in
            continuation.yield(.finished(summary))
            continuation.finish()
        }
    }

    func scan(_ request: ScanRequest) async -> ScanSummary {
        record(request)
    }

    @discardableResult
    private func record(_ request: ScanRequest) -> ScanSummary {
        guard case .files = request else { return ScanSummary() }
        lock.withLock { files += 1 }
        return ScanSummary(added: 1)
    }
}

/// A scripted `DownloadQueueing` that records what was asked of it and answers with a
/// caller-supplied ``EnqueueOutcome``.
@MainActor
final class ChatDownloadQueueDouble: DownloadQueueing {
    private(set) var enqueuedURLs: [[URL]] = []
    /// What the next `enqueue` answers. Defaults to "every URL landed".
    var outcome: EnqueueOutcome?

    var onQueueChanged: (@Sendable (DownloadQueueSnapshot) -> Void)?
    var onItemProgress: (@Sendable (UUID, DownloadState) -> Void)?

    func enqueue(urls: [URL]) async -> EnqueueOutcome {
        enqueuedURLs.append(urls)
        return outcome ?? EnqueueOutcome(added: urls.count, duplicatesDropped: 0)
    }

    func confirmPlaylist(_: UUID) async -> EnqueueOutcome {
        .zero
    }

    func cancelCurrent() {}
    func cancel(itemID _: UUID) {}
    func removePending(_: UUID) {}
    func movePending(_: UUID, to _: Int) {}
    func pause() {}
    func resume() {}
    func cancelAll() {}
}

// MARK: - The harness

@MainActor
final class ChatDownloadWiringHarness {
    let scanner = ChatDownloadCountingScanner()
    let database: AppDatabase
    let environment: AppEnvironment
    let settings: AppSettings
    let queueDouble = ChatDownloadQueueDouble()
    /// The real service `connectDownloads` built, kept so the suites can fire the
    /// closures production installed on it.
    let seams: DownloadQueueService
    /// A scratch folder standing in for the downloads destination. Deliberately NOT a
    /// library root, exactly as the shipped destination is not.
    let destination: URL

    init(autoImport: Bool = true, intelligenceEnabled: Bool = true) throws {
        let database = try AppDatabase.makeEmpty()
        self.database = database
        destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatDownloadWiring-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let rootsStore = GRDBLibraryRootsStore(
            repository: LibraryRootRepository(database),
            profileId: ProfileRecord.guestID
        )
        environment = AppEnvironment(Self.dependencies(database: database, rootsStore: rootsStore, scanner: scanner))
        settings =
            AppSettings(defaults: UserDefaults(suiteName: "\(Self.defaultsSuite).\(UUID().uuidString)") ?? .standard)
        settings.intelligenceEnabled = intelligenceEnabled
        settings.downloads.autoImportEnabled = autoImport
        settings.downloads.destinationPath = destination.path

        // The AI graph first, exactly as `live(settings:)` orders it — the seams must
        // survive being installed onto a graph that already existed.
        environment.connectAI(settings: settings)
        environment.connectDownloads(settings: settings)
        guard let service = environment.downloads as? DownloadQueueService else {
            throw ChatDownloadFixtureError.queueUnavailable
        }
        seams = service
        // Keep the real seams; route ENQUEUES to the double. See the file header.
        environment.downloads = queueDouble
    }

    /// The leaf dependencies, lifted out of ``init`` so that initializer stays inside
    /// SwiftLint's `function_body_length` ceiling. Same values, same order.
    private static func dependencies(
        database: AppDatabase,
        rootsStore: GRDBLibraryRootsStore,
        scanner: any LibraryScanning
    ) -> AppEnvironment.Dependencies {
        AppEnvironment.Dependencies(
            database: database,
            engine: FakePlaybackEngine(),
            artworkProvider: FakeArtworkProvider(),
            metadataFetcher: MockMetadataFetcher(),
            infoService: InfoService(fetcher: MockInfoFetcher(), database: database),
            lyricsProvider: FakeLyricsProvider(),
            presetStore: FakeEQPresetStore(),
            spectrumSource: SpectrumProvider(),
            scanner: scanner,
            watchService: LibraryWatchService(
                scanner: scanner,
                reconciler: AvailabilityReconciler(database),
                store: rootsStore
            ),
            libraryAccess: LibraryAccessController(
                store: rootsStore,
                picker: FakeFolderPicker(),
                probe: FakeFileAccessProbe(),
                settings: FakeSystemSettingsOpener()
            ),
            snapshotWriter: nil,
            profileService: ProfileService(
                profileRepository: ProfileRepository(database),
                defaults: UserDefaults(suiteName: "\(defaultsSuite).profiles") ?? .standard
            ),
            rootsStore: rootsStore,
            karaoke: .inert
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: destination)
    }

    // MARK: Pass-throughs

    var registry: SuggestionDownloadRegistry {
        environment.suggestionDownloadRegistry
    }

    var toast: ToastManager {
        environment.toast
    }

    var activeToastText: String? {
        environment.toast.activeToast?.text
    }

    var legacyImportedToast: String {
        String(localized: MacAMPStrings.downloadImportedToast)
    }

    // MARK: Driving the installed seams

    func item(_ videoID: String) throws -> DownloadItem {
        try DownloadItem(
            canonicalVideoID: videoID,
            sourceURL: downloadFixtureURL("https://www.youtube.com/watch?v=\(videoID)")
        )
    }

    /// Publishes a snapshot the way the driver does, so the production `onQueueChanged`
    /// chain teaches the video-id map about these rows.
    func publishPending(_ items: [DownloadItem]) async {
        seams.onQueueChanged?(DownloadQueueSnapshot(activeItems: [], pendingItems: items, isPaused: false))
        await environment.drainChatDownloadWork()
    }

    func emitProgress(_ itemID: UUID, _ state: DownloadState) async {
        seams.onItemProgress?(itemID, state)
        await environment.drainChatDownloadWork()
    }

    func finish(_ item: DownloadItem, at url: URL) async {
        seams.onItemFinished?(item, url)
        await environment.drainChatDownloadWork()
    }

    // MARK: Seeding

    /// A file in the destination folder WITH a library row behind it, so the appender's
    /// lookup resolves without the counting scanner having to do real work.
    @discardableResult
    func importedTrack(named name: String) throws -> (url: URL, trackId: Int64) {
        let url = destination.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data())
        let record = try TrackRepository(database).insert(TrackRecord(filePath: url.path))
        return (url, record.id ?? 0)
    }

    @discardableResult
    func makePlaylist(named name: String) throws -> Int64 {
        try PlaylistRepository(database).create(named: name, profileId: ProfileRecord.guestID).id ?? 0
    }

    func membership(playlistId: Int64) async throws -> [Int64] {
        try await PlaylistRepository(database)
            .playlistTracksPage(playlistId: playlistId)
            .items
            .compactMap(\.track.id)
    }

    /// Polls until `condition` holds, so an assertion about a task the harness does not
    /// own (the LEGACY import, spawned by `wireDownloadSeams`) is not a race.
    func waitUntil(_ condition: () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private static let defaultsSuite = "com.example.macamp.tests.chatDownloads"
}

/// A URL from a literal, without a force-unwrap (SwiftLint `force_unwrapping`).
func downloadFixtureURL(_ string: String) throws -> URL {
    try #require(URL(string: string))
}
