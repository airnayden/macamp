// AppEnvironment — the iOS / iPadOS composition root.
//
// Mirrors the macOS composition root (Task 25): it builds the entire object graph
// once and injects it through the SwiftUI environment
// (`@Environment(AppEnvironment.self)`). `live()` wires the real stack (the
// on-disk `AppDatabase.shared`, the real `SFBPlaybackEngine` — ADR Option A is
// verified on iOS — the SFB/TagLib metadata reader, the GRDB-backed repositories
// and preset store); `preview()` swaps in an in-memory database and the modules'
// shipped fakes so previews never touch disk, audio or the network.
//
// The wiring is identical to macOS — only the leaf dependencies differ — so they
// are bundled into a single ``Dependencies`` value, keeping the designated
// initializer at one parameter. There is NO AppKit/UIKit here (this is the app
// shell, not PlayerCore, but the graph itself is pure PlayerCore).
//
// AVAudioSession is owned by ``AudioSessionController`` (Task 34): the engine is
// constructed here and the controller — built alongside it — configures the
// `.playback` category, activates the session and handles interruptions / route
// changes. Only ``live()`` activates it; ``preview()`` builds it but never touches
// the real session, keeping previews hermetic.
//
// The type is `@Observable` so it can be injected with `@Environment(_:)`; it is
// itself just a container — change tracking happens inside the nested view models
// (each already `@MainActor @Observable`), so every stored property is
// `@ObservationIgnored`.
import Artwork
import AudioEngine
import DSP
import Foundation
import GRDB
import Lyrics
import Metadata
import Models
import Observation
import Persistence
import Services
import ViewModels
import Visualizer

/// The single, app-wide object graph (composition root) injected into the UI.
@MainActor
@Observable
final class AppEnvironment {
    // MARK: View models (the UI surface)

    /// Browses the library (tracks / albums / artists), keyset-paginated.
    @ObservationIgnored let library: LibraryViewModel
    /// Debounced full-text search over the track FTS5 index.
    @ObservationIgnored let search: SearchViewModel
    /// The now-playing transport (play/pause/seek/next/previous + artwork).
    @ObservationIgnored let player: PlayerViewModel
    /// The play-queue editor (add/remove/move/shuffle/repeat).
    @ObservationIgnored let queue: QueueViewModel
    /// The ten-band graphic EQ + preset selection.
    @ObservationIgnored let equalizer: EQViewModel
    /// The pull-based visualizer frame source + mode.
    @ObservationIgnored let visualizer: VisualizerViewModel
    /// Synced-lyrics resolution + active line/word tracking.
    @ObservationIgnored let lyrics: LyricsViewModel
    /// Browses playlists (keyset-paginated, with track counts) and edits a
    /// playlist's ordered membership.
    @ObservationIgnored let playlists: PlaylistViewModel
    /// Imports/exports playlists to/from m3u / m3u8 / pls / JSPF files,
    /// surfacing entries that did not resolve to a library track.
    @ObservationIgnored let playlistImportExport: PlaylistImportExportViewModel

    // MARK: Services + infrastructure (retained for the app's lifetime)

    /// The now-playing source of truth bridging the queue to the engine.
    @ObservationIgnored let coordinator: PlaybackCoordinator
    /// The active-profile session state machine. iOS ships Guest-fixed (no profile
    /// UI yet); retained so the shared view models compile against the seam.
    @ObservationIgnored let profileService: any ProfileManaging
    /// The two play-capture consumers, delivered as one value because the designated
    /// initializer sits at the SwiftLint body-length ceiling.
    @ObservationIgnored let playHooks: PlayHooks
    /// Writes the per-profile listening history (v15 `playEvent`). iOS captures the
    /// same events as macOS; it has no quit hook, so there is no termination flush
    /// here — a backgrounded iOS app is not torn down mid-write the way a Quit is.
    var playEventRecorder: PlayEventRecorder {
        playHooks.recorder
    }

    /// Captures which PARTS of a track get replayed (v15 `playSegmentHeat`).
    var playSegmentTracker: PlaySegmentTracker {
        playHooks.tracker
    }

    /// Folds aged play events into monthly rollups (v15 `playEventRollup`). Started by
    /// ``live()``, never by ``preview()``; `lazy` costs the capped initializer no line.
    @ObservationIgnored private(set) lazy var playEventCompactionTrigger =
        PlayEventCompactionTrigger(compactor: PlayEventCompactor(database))
    /// The resumable, bounded-memory library importer.
    @ObservationIgnored let scanner: any LibraryScanning
    @ObservationIgnored let libraryAccess: SecurityScopedAccessOwner
    /// Keeps `MPNowPlayingInfoCenter` in sync with the transport.
    @ObservationIgnored let nowPlaying: NowPlayingService
    /// Applies ReplayGain to the engine's global gain on track change.
    @ObservationIgnored let replayGain: ReplayGainService
    /// The migrated application database (build repositories from this).
    @ObservationIgnored let database: AppDatabase
    /// The playback engine the transport + EQ drive.
    @ObservationIgnored let engine: any PlaybackEngine
    /// Resolves cover art for album/artist detail headers (embedded art, no network).
    @ObservationIgnored let artworkProvider: any ArtworkProviding
    /// Owns the iOS `AVAudioSession`: interruptions, route changes, background.
    @ObservationIgnored let audioSession: AudioSessionController
    @ObservationIgnored let remoteCommands: RemoteCommandHandler
    /// Resolves missing tag fields from an online database (tag-editor Auto-fill).
    @ObservationIgnored let metadataFetcher: any OnlineMetadataFetching
    /// Background, pausable auto-enrichment of imported tracks (metadata + lyrics).
    @ObservationIgnored let enrichment: EnrichmentService
    /// Observable projection of ``enrichment`` for the enrichment progress UI.
    @ObservationIgnored let enrichmentViewModel: EnrichmentViewModel
    /// Resolves + caches narrative artist/album/track info (MusicBrainz + Wikipedia).
    @ObservationIgnored let infoService: InfoService
    /// The local-AI object graph, or `nil` while the Intelligence master toggle is
    /// off. Observable (not `@ObservationIgnored`) so the Auto Mixes section
    /// disappears the moment the graph is torn down. Assigned ONLY by
    /// ``rebuildAI(settings:)`` (a sibling-file extension, so `private(set)` is not
    /// available); treat it as read-only everywhere else.
    var intelligence: AIStack?

    private init(_ dependencies: Dependencies) {
        let database = dependencies.database
        self.database = database
        scanner = dependencies.scanner
        libraryAccess = dependencies.libraryAccess
        metadataFetcher = dependencies.metadataFetcher
        infoService = dependencies.infoService

        profileService = dependencies.profileService
        let profileId = dependencies.profileService.activeProfile.id ?? ProfileRecord.guestID

        let trackRepository = TrackRepository(database)
        let albumRepository = AlbumRepository(database)
        let artistRepository = ArtistRepository(database)

        let engine = dependencies.engine
        self.engine = engine
        artworkProvider = dependencies.artworkProvider
        let coordinator = PlaybackCoordinator(
            engine: engine,
            randomNumberGenerator: dependencies.randomNumberGenerator
        )
        self.coordinator = coordinator
        let nowPlaying = NowPlayingService(snapshotWriter: dependencies.snapshotWriter)
        self.nowPlaying = nowPlaying
        replayGain = Self.makeReplayGain(engine: engine, database: database)
        remoteCommands = Self.makeRemoteCommands(coordinator: coordinator)
        playHooks = Self.makePlayHooks(coordinator, dependencies)
        audioSession = AudioSessionController(coordinator: coordinator, nowPlaying: nowPlaying)

        player = PlayerViewModel(coordinator: coordinator, artworkProvider: dependencies.artworkProvider)
        Self.wirePlaybackFeeds(coordinator, engine: engine, nowPlaying: nowPlaying, hooks: playHooks)

        library = LibraryViewModel(
            trackRepository: trackRepository,
            albumRepository: albumRepository,
            artistRepository: artistRepository,
            databaseReader: database.writer,
            activeProfileId: profileId
        )
        search = SearchViewModel(repository: trackRepository, activeProfileId: profileId)
        queue = QueueViewModel(coordinator: coordinator)
        equalizer = EQViewModel(engine: engine, presetStore: dependencies.presetStore)
        visualizer = VisualizerViewModel(source: dependencies.spectrumSource)
        lyrics = LyricsViewModel(provider: dependencies.lyricsProvider)
        playlists = PlaylistViewModel(repository: PlaylistRepository(database), activeProfileId: profileId)
        playlistImportExport = PlaylistImportExportViewModel(
            playlistIO: PlaylistFileIO(database),
            repository: PlaylistRepository(database)
        )

        let enrichmentGraph = Self.makeEnrichment(dependencies, database: database)
        enrichment = enrichmentGraph.service
        enrichmentViewModel = enrichmentGraph.viewModel
        Self.wireReplayGain(self, coordinator: coordinator)
    }
}

// MARK: - Factories

extension AppEnvironment {
    /// The production environment: on-disk database, real audio engine, real
    /// SFB/TagLib metadata reader, GRDB repositories and preset store.
    static func live() -> AppEnvironment {
        let database = AppDatabase.shared
        let roots = SecurityScopedBookmarkManager(store: GRDBBookmarkStore(database: database)).resolveRoots()
        let libraryAccess = SecurityScopedAccessOwner(roots: roots.map(\.url))
        let metadataReader = SFBMetadataReader()
        let limiter = MusicBrainzRateLimiter()
        let environment = AppEnvironment(
            Dependencies(
                database: database,
                engine: SFBPlaybackEngine(),
                artworkProvider: ArtworkService(metadataReader: metadataReader),
                lyricsProvider: LyricsService(
                    metadataReader: metadataReader,
                    database: database,
                    lrclib: LRCLIBClient()
                ),
                presetStore: GRDBEQPresetStore(database),
                spectrumSource: SpectrumProvider(),
                scanner: LibraryScanner(
                    database: database,
                    metadataReader: metadataReader,
                    excludedDirectories: { InstrumentalCacheLocation.defaultDirectory().map { [$0] } ?? [] }
                ),
                metadataFetcher: MusicBrainzClient(limiter: limiter),
                infoService: InfoService(
                    fetcher: MusicBrainzInfoClient(limiter: limiter),
                    database: database
                ),
                snapshotWriter: nil,
                profileService: ProfileService(
                    profileRepository: ProfileRepository(database),
                    defaults: .standard
                ),
                libraryAccess: libraryAccess
            )
        )
        environment.audioSession.activate()
        environment.playEventCompactionTrigger.start()
        return environment
    }

    /// A hermetic environment for SwiftUI previews: an empty in-memory database
    /// and the modules' shipped fakes (no disk, audio or network).
    static func preview() -> AppEnvironment {
        do {
            let database = try AppDatabase.makeEmpty()
            return AppEnvironment(
                Dependencies(
                    database: database,
                    engine: FakePlaybackEngine(),
                    artworkProvider: FakeArtworkProvider(),
                    lyricsProvider: FakeLyricsProvider(),
                    presetStore: FakeEQPresetStore(),
                    spectrumSource: SpectrumProvider(),
                    scanner: FakeLibraryScanner(),
                    metadataFetcher: MockMetadataFetcher(),
                    infoService: InfoService(fetcher: MockInfoFetcher(), database: database),
                    snapshotWriter: nil,
                    profileService: ProfileService(
                        profileRepository: ProfileRepository(database),
                        defaults: UserDefaults(suiteName: "com.example.macamp.preview.profiles") ?? .standard
                    )
                )
            )
        } catch {
            fatalError("preview database unavailable: \(error)")
        }
    }
}

// MARK: - Dependencies

extension AppEnvironment {
    /// The leaf dependencies that distinguish a live environment from a preview
    /// one. Bundled into one value so the designated initializer takes a single
    /// parameter while the heavy wiring stays shared.
    struct Dependencies {
        var database: AppDatabase
        var engine: any PlaybackEngine
        var artworkProvider: any ArtworkProviding
        var lyricsProvider: any LyricsProviding
        var presetStore: any EQPresetStoring
        var spectrumSource: any SpectrumSource
        var scanner: any LibraryScanning
        var metadataFetcher: any OnlineMetadataFetching
        var infoService: InfoService
        var snapshotWriter: (any SnapshotWriting)?
        var profileService: any ProfileManaging
        var libraryAccess = SecurityScopedAccessOwner()
        var randomNumberGenerator: any RandomNumberGenerator = SystemRandomNumberGenerator()
    }
}
