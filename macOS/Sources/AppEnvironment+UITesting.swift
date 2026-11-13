// AppEnvironment+UITesting — hermetic UI-test seam.
//
// Split out of `AppEnvironment.swift` to keep that composition-root file under the
// SwiftLint `file_length` budget. `liveForUITesting()` builds a throwaway database
// seeded with fixture tracks and a throwaway `UserDefaults` suite, so the UI test
// never touches the user's real Application Support library or standard defaults.
// Compiled out of Release and inert unless the launch environment sets
// `UITEST_SEED_PATH`, so shipping behavior is completely unaffected.
import Artwork
import AudioEngine
import DSP
import Foundation
import GRDB
import Lyrics
import Metadata
import Models
import os
import Persistence
import Separation
import Services
import ViewModels
import Visualizer

#if DEBUG
    extension AppEnvironment {
        /// Returns a hermetic composition root built on a throwaway temp database
        /// (seeded with two fixture tracks) and a throwaway `UserDefaults` suite, so
        /// the UI test never touches the user's real Application Support library or
        /// standard defaults. All other services mirror `preview()`'s fakes.
        static func liveForUITesting(settings: AppSettings) -> AppEnvironment? {
            let launchEnvironment = ProcessInfo.processInfo.environment
            guard let seedPath = launchEnvironment["UITEST_SEED_PATH"],
                  let database = try? makeUITestDatabase(
                      seedDirectory: seedPath,
                      options: UITestFixtureOptions.fromLaunchEnvironment(launchEnvironment)
                  )
            else { return nil }
            let runID = launchEnvironment["UITEST_RUN_ID"] ?? UUID().uuidString
            let defaults = UserDefaults(suiteName: "com.example.macamp.uitest.\(runID)") ?? .standard
            let rootsStore = GRDBLibraryRootsStore(
                repository: LibraryRootRepository(database),
                profileId: ProfileRecord.guestID
            )
            let watchService = LibraryWatchService(
                scanner: FakeLibraryScanner(),
                reconciler: AvailabilityReconciler(database),
                store: rootsStore
            )
            let legacyCachedSource = legacyCachedSource(seedPath: seedPath, environment: launchEnvironment)
            let karaoke = launchEnvironment["UITEST_KARAOKE_FAKE"] == "1"
                ? makeUITestKaraokeStack(
                    hold: launchEnvironment["UITEST_KARAOKE_HOLD"] == "1",
                    legacyCachedSource: legacyCachedSource
                )
                : .inert
            let environment = AppEnvironment(uiTestDependencies(
                database: database,
                defaults: defaults,
                rootsStore: rootsStore,
                watchService: watchService,
                karaoke: karaoke
            ))
            environment.connectUITestKaraoke(karaoke, settings: settings, launchEnvironment: launchEnvironment)
            // Mirrors `live(settings:)`, which returns BEFORE its own `connectAI` call on
            // this path: without it every AI-gated surface is permanently absent under
            // XCUITest and its "hidden when off" assertions would pass vacuously.
            environment.connectAI(settings: settings)
            // Same reasoning, and safe for the same reason the real graph is: building
            // the queue spawns nothing. `DownloadToolManager.prepare()` is lazy (first
            // download), and `DownloadQueueService` is inert until `enqueue`. Without
            // this the Downloads pane has no view model under XCUITest and every
            // assertion about it would pass or fail for the wrong reason.
            environment.connectDownloads(settings: settings)
            return environment
        }

        /// The fake leaf dependencies, split out purely to keep ``liveForUITesting(settings:)``
        /// inside the function-length budget.
        private static func uiTestDependencies(
            database: AppDatabase,
            defaults: UserDefaults,
            rootsStore: GRDBLibraryRootsStore,
            watchService: LibraryWatchService,
            karaoke: KaraokeStack
        ) -> Dependencies {
            Dependencies(
                database: database,
                engine: FakePlaybackEngine(),
                artworkProvider: FakeArtworkProvider(),
                metadataFetcher: MockMetadataFetcher(),
                infoService: InfoService(fetcher: MockInfoFetcher(), database: database),
                lyricsProvider: ProcessInfo.processInfo.environment["UITEST_LYRICS_HTTP_FAILURE"] == "1"
                    ? UITestFailingLyricsProvider()
                    : FakeLyricsProvider(),
                presetStore: FakeEQPresetStore(),
                spectrumSource: SpectrumProvider(),
                scanner: FakeLibraryScanner(),
                watchService: watchService,
                libraryAccess: LibraryAccessController(
                    store: rootsStore,
                    picker: FakeFolderPicker(),
                    probe: FakeFileAccessProbe(),
                    settings: FakeSystemSettingsOpener()
                ),
                snapshotWriter: nil,
                profileService: ProfileService(profileRepository: ProfileRepository(database), defaults: defaults),
                rootsStore: rootsStore,
                karaoke: karaoke
            )
        }

        /// Wires the karaoke stack into `self`, then — for `UITEST_KARAOKE_START_PAUSED` —
        /// pauses the render service at launch so scheduled tracks sit pending until an explicit
        /// resume, instead of the instant fake separator draining them before they can be
        /// observed. `pause()` ignores `enabled` and survives the later `setEnabled(true)`, so a
        /// track requested while the queue is enabled still appends without auto-starting the driver.
        private func connectUITestKaraoke(
            _ karaoke: KaraokeStack,
            settings: AppSettings,
            launchEnvironment: [String: String]
        ) {
            // Enable karaoke IN-MEMORY at launch. The launch-argument value is a String,
            // while AppSettings reads this preference as Bool, so it must be applied here.
            if launchEnvironment["UITEST_KARAOKE_ENABLED"] == "1" {
                settings.karaokeEnabled = true
            }
            let cacheDirectory = settings.karaokeCacheDirectoryPath.map { URL(fileURLWithPath: $0) }
                ?? InstrumentalCacheLocation.defaultDirectory()
            connectKaraoke(
                stack: karaoke,
                settings: settings,
                cacheDirectoryBox: OSAllocatedUnfairLock<URL?>(initialState: cacheDirectory),
                qualityBox: OSAllocatedUnfairLock<InstrumentalRenderQuality>(initialState: settings.karaokeQuality)
            )
            if launchEnvironment["UITEST_KARAOKE_START_PAUSED"] == "1" {
                karaokeRender?.pause()
            }
        }

        /// Builds the `UITEST_KARAOKE_FAKE=1` stack: an always-available fake separator
        /// wired to a shared instrumental cache. The cache starts empty unless
        /// `UITEST_KARAOKE_LEGACY_CACHED=1` seeds an identity-less fixture entry. Pressing the
        /// render action runs an
        /// on-demand render whose `store` fires the cache change-seam, so the ready badge,
        /// the sidebar Karaoke section, and the button's `.ready`/`.active` states all
        /// light up — the full on-demand flow, no Core ML model required.
        ///
        /// - Parameter hold: when `true` (`UITEST_KARAOKE_HOLD`) the fake separator blocks
        ///   each render on a cancellable sleep instead of completing, so an in-flight item
        ///   stays observable (its row ring, the queue's "Now Rendering" stop control) until
        ///   `stopCurrent()`/`startNow()` cancels it — the deterministic seam for the
        ///   start-now / stop / queued-badge UITests the instant fake can't hold still for.
        private static func makeUITestKaraokeStack(hold: Bool, legacyCachedSource: URL?) -> KaraokeStack {
            let modelSHA = "uitest-karaoke-model"
            let cache = UITestInstrumentalCache(legacyCachedSource: legacyCachedSource, modelSHA: modelSHA)
            return KaraokeStack(
                separator: UITestStemSeparator(cache: cache, modelSHA: modelSHA, hold: hold),
                cache: cache,
                modelSHA: modelSHA,
                separatorAvailable: true
            )
        }

        private static func legacyCachedSource(seedPath: String, environment: [String: String]) -> URL? {
            guard environment["UITEST_KARAOKE_LEGACY_CACHED"] == "1" else { return nil }
            return URL(fileURLWithPath: seedPath, isDirectory: true)
                .appendingPathComponent("Aurora Anthem.mp3")
                .resolvingSymlinksInPath()
                .standardizedFileURL
        }

        /// The optional fixtures run in DEPENDENCY order, and the analysis rows run
        /// LAST on purpose: they fingerprint whatever rows exist at that moment, and
        /// both earlier fixtures insert tracks and rewrite `fileSize`.
        private static func makeUITestDatabase(
            seedDirectory: String,
            options: UITestFixtureOptions
        ) throws -> AppDatabase {
            let folder = URL(fileURLWithPath: seedDirectory, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let databaseURL = folder.appendingPathComponent("uitest-library.sqlite")
            let databaseExists = FileManager.default.fileExists(atPath: databaseURL.path)
            if !options.preserveExisting {
                try? FileManager.default.removeItem(at: databaseURL)
            }
            var configuration = Configuration()
            configuration.journalMode = .wal
            let database = try AppDatabase(DatabasePool(path: databaseURL.path, configuration: configuration))
            if !options.preserveExisting || !databaseExists {
                try seedFixtureTracks(
                    into: database,
                    directory: folder,
                    lifetimePlayCounts: options.lifetimePlayCounts
                )
                if options.folderTree {
                    try FolderTreeUITestFixture.seed(into: database, directory: folder)
                }
                if options.contextualActions {
                    try AIContextualFixture.seed(into: database)
                }
                if options.hygiene {
                    try HygieneFixture.seed(into: database)
                }
                if let audioDirectory = options.realAudioDirectory {
                    try RealAudioLibraryFixture.seed(
                        into: database,
                        directoryPath: audioDirectory,
                        genre: options.realAudioGenre
                    )
                }
                if let shape = options.audioFeatures {
                    try AudioFeatureFixture.seed(into: database, shape: shape)
                }
            }
            return database
        }

        /// `lifetimePlayCounts` adds per-profile counters and deliberately NO
        /// `playEvent` rows: a library predating the v15 event log.
        private static func seedFixtureTracks(
            into database: AppDatabase,
            directory: URL,
            lifetimePlayCounts: Bool
        ) throws {
            let titles = ["Aurora Anthem", "Zephyr Waltz"]
            try database.writer.write { db in
                for (index, title) in titles.enumerated() {
                    let fileURL = directory.appendingPathComponent("\(title).mp3")
                    FileManager.default.createFile(atPath: fileURL.path, contents: Data())
                    // Canonicalize so the DB path matches the karaoke ready path: under
                    // NSTemporaryDirectory() the /var → /private/var symlink otherwise makes
                    // tracksByPaths(readyPaths) miss (SeparationCacheKey resolves symlinks).
                    let canonicalPath = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
                    var record = TrackRecord(
                        filePath: canonicalPath,
                        title: title,
                        sortTitle: title.lowercased(),
                        artistName: "Fixture Artist",
                        duration: 123,
                        availability: .present
                    )
                    try record.insert(db)
                    guard lifetimePlayCounts, let trackId = record.id else { continue }
                    let plays = titles.count - index
                    try ProfileTrackStateRecord(
                        profileId: ProfileRecord.guestID,
                        trackId: trackId,
                        playCount: plays,
                        listenedCount: plays
                    ).insert(db)
                }
            }
        }
    }

    /// Always-available ``StemSeparating`` for the karaoke UI-test seam. Mirrors how the
    /// production `SeparationPipeline` behaves for the flow: it reports 0→1 progress and
    /// STORES the (echoed) source URL into the SHARED cache under its on-disk identity, so
    /// the cache change-seam fires and the ready store / badges / sidebar update — without
    /// Core ML or any real audio processing.
    private struct UITestStemSeparator: StemSeparating {
        let cache: UITestInstrumentalCache
        let modelSHA: String
        /// When `true`, `separate` reports partial progress and then blocks on a cancellable
        /// sleep instead of completing, so an in-flight render stays observable until
        /// `KaraokeRenderService.stopCurrent()`/`startNow()` cancels the detached task
        /// (`Task.sleep` throws `CancellationError`). Used by the queue start-now / stop /
        /// queued-badge UITests, where the instant path drains too fast to observe.
        let hold: Bool

        var availability: SeparationAvailability {
            get async { .available }
        }

        func separate(url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
            progress(0)
            if hold {
                progress(0.5)
                try await Task.sleep(for: .seconds(600))
            }
            let identity = try SeparationCacheKey.sourceIdentity(for: url)
            let key = SeparationCacheKey(identity: identity, modelSHA: modelSHA)
            let stored = try await cache.store(url, for: key, identity: identity)
            progress(1)
            return stored
        }
    }

    /// In-memory ``InstrumentalCaching`` for the karaoke UI-test seam. Starts empty unless
    /// the legacy cache-hit scenario supplies an identity-less entry; the fake separator
    /// otherwise populates it on demand via ``store(_:for:identity:)``, whose
    /// change-seam drives the ready store so badges / sidebar update mid-flow.
    private actor UITestInstrumentalCache: InstrumentalCaching {
        private var storage: [SeparationCacheKey: URL] = [:]
        private var identities: [SeparationCacheKey: SourceIdentity] = [:]
        private var sequence = 0
        private var onEntriesChanged: (@Sendable (Int, [ReadyRecord]) -> Void)?

        init(legacyCachedSource: URL?, modelSHA: String) {
            guard let legacyCachedSource,
                  let identity = try? SeparationCacheKey.sourceIdentity(for: legacyCachedSource)
            else { return }
            let key = SeparationCacheKey(identity: identity, modelSHA: modelSHA)
            storage[key] = legacyCachedSource
        }

        func cachedInstrumental(for key: SeparationCacheKey) -> URL? {
            storage[key]
        }

        @discardableResult
        func store(_ source: URL, for key: SeparationCacheKey, identity: SourceIdentity? = nil) throws -> URL {
            storage[key] = source
            if let identity {
                identities[key] = identity
            }
            emitEntriesChanged()
            return source
        }

        func recordSourceIdentity(for key: SeparationCacheKey, identity: SourceIdentity) {
            guard storage[key] != nil else { return }
            identities[key] = identity
            emitEntriesChanged()
        }

        func pin(_: SeparationCacheKey) {}
        func unpin(_: SeparationCacheKey) {}

        var totalBytes: Int64 {
            0
        }

        func clearAll() throws {
            storage.removeAll()
            identities.removeAll()
            emitEntriesChanged()
        }

        @discardableResult
        func remove(sourcePaths: [String]) throws -> Int {
            let targets = Set(sourcePaths.map(CanonicalSourcePath.canonical))
            let victims = storage.keys.filter { key in
                guard let identity = identities[key] else { return false }
                return targets.contains(CanonicalSourcePath.canonical(identity.path))
            }
            guard !victims.isEmpty else { return 0 }
            for key in victims {
                storage[key] = nil
                identities[key] = nil
            }
            emitEntriesChanged()
            return victims.count
        }

        func readySnapshot() -> (sequence: Int, records: [ReadyRecord]) {
            (sequence, readyRecords())
        }

        func setOnEntriesChanged(_ handler: (@Sendable (Int, [ReadyRecord]) -> Void)?) {
            onEntriesChanged = handler
        }

        func setMaxByteSize(_: Int64) {}

        func relocate(to _: URL) throws -> Bool {
            emitEntriesChanged()
            return true
        }

        private func readyRecords() -> [ReadyRecord] {
            storage.keys.compactMap { key in
                guard let identity = identities[key] else { return nil }
                return ReadyRecord(
                    sourcePath: identity.path,
                    sourceFileSize: identity.fileSize,
                    sourceMTime: identity.mtime,
                    keyHex: key.hexValue
                )
            }
        }

        private func emitEntriesChanged() {
            sequence += 1
            onEntriesChanged?(sequence, readyRecords())
        }
    }

    private struct UITestFailingLyricsProvider: LyricsProviding {
        func resolveLyrics(for _: LyricsRequest, options: LyricsOptions) async throws -> Lyrics? {
            guard options.allowOnlineFetch else { return nil }
            try await Task.sleep(for: .seconds(6))
            throw OnlineLyricsError.httpStatus(503)
        }
    }
#endif
