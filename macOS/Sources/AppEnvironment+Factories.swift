// AppEnvironment+Factories — the two ways the composition root is built.
//
// Moved VERBATIM out of `AppEnvironment.swift` (a pure relocation, no code change) so
// that file keeps headroom under the SwiftLint `file_length` ceiling for the
// chat-download stored properties. `live(settings:)`, its private leaf-dependency
// factory, and `preview()` keep their names, their access levels and their call sites.
//
// They belong together: both answer the same question — which leaves this graph is
// assembled over — and differ in nothing else. The class declaration, the designated
// initializer and the stored properties stay in `AppEnvironment.swift`, because Swift
// does not allow stored properties in an extension.
import Artwork
import AudioEngine
import DSP
import Foundation
import Lyrics
import Metadata
import Models
import Observation
import os
import Persistence
import Separation
import Services
import ViewModels
import Visualizer

// MARK: - Factories

public extension AppEnvironment {
    /// The production environment: on-disk database, real audio engine, real
    /// SFB/TagLib metadata reader, GRDB repositories and preset store.
    static func live(settings: AppSettings) -> AppEnvironment {
        #if DEBUG
            // TEST-ONLY: the `macampMacUITests` XCUITest smoke suite seeds a
            // hermetic environment via a launch-environment key; every normal /
            // production launch skips this (the env var is absent).
            if let uiTest = liveForUITesting(settings: settings) { return uiTest }
        #endif
        // Resolve the karaoke cache directory + render quality from `AppSettings` (which
        // is `@MainActor`) ONCE, here on the main actor, into two lock boxes so the
        // off-main scanner exclusion + render pipeline never read `AppSettings` directly.
        let cacheDirectory = settings.karaokeCacheDirectoryPath.map { URL(fileURLWithPath: $0) }
            ?? InstrumentalCacheLocation.defaultDirectory()
        let cacheDirectoryBox = OSAllocatedUnfairLock<URL?>(initialState: cacheDirectory)
        let qualityBox = OSAllocatedUnfairLock<InstrumentalRenderQuality>(initialState: settings.karaokeQuality)
        let karaoke = makeKaraokeStack(cacheDirectory: cacheDirectory, qualityBox: qualityBox)
        let dependencies = makeLiveDependencies(karaoke: karaoke, cacheDirectoryBox: cacheDirectoryBox)
        let environment = AppEnvironment(dependencies)
        environment.connectKaraoke(
            stack: karaoke,
            settings: settings,
            cacheDirectoryBox: cacheDirectoryBox,
            qualityBox: qualityBox
        )
        environment.connectAI(settings: settings)
        environment.connectDownloads(settings: settings)
        environment.connectFolderSort(settings: settings)
        environment.connectOutputRouting(settings: settings)
        environment.connectCrossfeed()
        return environment
    }

    /// Builds the production leaf dependencies (on-disk DB, real engine, GRDB repos,
    /// online clients) for ``live()``, keeping that factory under the body-length budget.
    private static func makeLiveDependencies(
        karaoke: KaraokeStack,
        cacheDirectoryBox: OSAllocatedUnfairLock<URL?>
    ) -> Dependencies {
        let database = AppDatabase.shared
        let metadataReader = SFBMetadataReader()
        let scanner = LibraryScanner(
            database: database,
            metadataReader: metadataReader,
            excludedDirectories: {
                (cacheDirectoryBox.withLock { $0 }.map { [$0] } ?? []) + DownloadPrivateDirectories.excluded
            }
        )
        let profileService = ProfileService(profileRepository: ProfileRepository(database), defaults: .standard)
        let rootsStore = GRDBLibraryRootsStore.live(
            database: database,
            activeProfileId: profileService.activeProfile.id ?? ProfileRecord.guestID
        )
        let watchService = LibraryWatchService(
            scanner: scanner,
            reconciler: AvailabilityReconciler(database),
            store: rootsStore
        )
        let engine = SFBPlaybackEngine()
        let limiter = MusicBrainzRateLimiter()
        return Dependencies(
            database: database,
            engine: engine,
            artworkProvider: ArtworkService(metadataReader: metadataReader),
            metadataFetcher: MusicBrainzClient(limiter: limiter),
            infoService: InfoService(
                fetcher: MusicBrainzInfoClient(limiter: limiter),
                database: database
            ),
            lyricsProvider: LyricsService(
                metadataReader: metadataReader,
                database: database,
                lrclib: LRCLIBClient()
            ),
            presetStore: GRDBEQPresetStore(database),
            spectrumSource: engine.spectrumProvider,
            scanner: scanner,
            watchService: watchService,
            libraryAccess: LibraryAccessController(
                store: rootsStore,
                karaokeCacheDirectory: { cacheDirectoryBox.withLock { $0 } }
            ),
            snapshotWriter: nil,
            profileService: profileService,
            rootsStore: rootsStore,
            karaoke: karaoke
        )
    }

    /// A hermetic environment for SwiftUI previews: an empty in-memory database
    /// and the modules' shipped fakes (no disk, audio or network).
    static func preview() -> AppEnvironment {
        do {
            let database = try AppDatabase.makeEmpty()
            let rootsStore = GRDBLibraryRootsStore(
                repository: LibraryRootRepository(database),
                profileId: ProfileRecord.guestID
            )
            let watchService = LibraryWatchService(
                scanner: FakeLibraryScanner(),
                reconciler: AvailabilityReconciler(database),
                store: rootsStore
            )
            return AppEnvironment(
                Dependencies(
                    database: database,
                    engine: FakePlaybackEngine(),
                    artworkProvider: FakeArtworkProvider(),
                    metadataFetcher: MockMetadataFetcher(),
                    infoService: InfoService(fetcher: MockInfoFetcher(), database: database),
                    lyricsProvider: FakeLyricsProvider(),
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
                    profileService: ProfileService(
                        profileRepository: ProfileRepository(database),
                        defaults: UserDefaults(suiteName: "com.example.macamp.preview.profiles") ?? .standard
                    ),
                    rootsStore: rootsStore,
                    karaoke: .inert
                )
            )
        } catch {
            fatalError("preview database unavailable: \(error)")
        }
    }
}
