// AppEnvironment — the macOS composition root.
//
// Builds the entire object graph once and injects it through the SwiftUI
// environment (`@Environment(AppEnvironment.self)`). `live()` wires the real
// stack (the on-disk `AppDatabase.shared`, the real `SFBPlaybackEngine`, the
// SFB/TagLib metadata reader, the GRDB-backed repositories and preset store);
// `preview()` swaps in an in-memory database and the modules' shipped fakes so
// previews and previews-only scaffolding never touch disk, audio or the network.
//
// Construction is identical for both — the repositories, coordinator, services
// and the eight view models are assembled the same way — so only the leaf
// dependencies differ. Those leaves are bundled into a single ``Dependencies``
// value, which keeps the designated initializer at one parameter.
//
// The type is `@Observable` so it can be injected with `@Environment(_:)`; it is
// itself just a container — change tracking happens inside the nested view
// models (each already `@MainActor @Observable`), so every stored property here
// is `@ObservationIgnored`.
import AIConnectorKit
import Artwork
import AudioEngine
import DSP
import Foundation
import GRDB
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

/// The single, app-wide object graph (composition root) injected into the UI.
@MainActor
@Observable
public final class AppEnvironment {
    // MARK: View models (the UI surface)

    /// Browses the library (tracks / albums / artists), keyset-paginated.
    @ObservationIgnored public let library: LibraryViewModel
    /// Debounced full-text search over the track FTS5 index.
    @ObservationIgnored public let search: SearchViewModel
    /// The now-playing transport (play/pause/seek/next/previous + artwork).
    @ObservationIgnored public let player: PlayerViewModel
    /// The play-queue editor (add/remove/move/shuffle/repeat).
    @ObservationIgnored public let queue: QueueViewModel
    /// The ten-band graphic EQ + preset selection.
    @ObservationIgnored public let equalizer: EQViewModel
    /// The pull-based visualizer frame source + mode.
    @ObservationIgnored public let visualizer: VisualizerViewModel
    /// Synced-lyrics resolution + active line/word tracking.
    @ObservationIgnored public let lyrics: LyricsViewModel
    /// Browses the tracks whose lyrics are already cached, and previews any one of
    /// them through its OWN resolver — a preview never disturbs ``lyrics``.
    @ObservationIgnored public let lyricsBrowser: LyricsBrowserViewModel
    /// Browses playlists (keyset-paginated, with track counts) and edits a
    /// playlist's ordered membership.
    @ObservationIgnored public let playlists: PlaylistViewModel
    /// Imports/exports playlists to/from m3u / m3u8 / pls / JSPF files,
    /// surfacing entries that did not resolve to a library track.
    @ObservationIgnored public let playlistImportExport: PlaylistImportExportViewModel

    // MARK: Services + infrastructure (retained for the app's lifetime)

    /// The now-playing source of truth bridging the queue to the engine.
    @ObservationIgnored public let coordinator: PlaybackCoordinator
    /// The surface that most recently replaced the context queue.
    public private(set) var currentSource: PlaybackSource?
    /// Persists the active profile's queue, source and live playback position.
    @ObservationIgnored public private(set) lazy var playbackStatePersister = PlaybackStatePersister(
        coordinator: coordinator,
        repository: ProfilePlaybackStateRepository(database),
        databaseWriter: database.writer,
        profileId: { [weak self] in
            self?.profileService.activeProfile.id ?? ProfileRecord.guestID
        },
        currentSource: { [weak self] in self?.currentSource }
    )
    /// The per-profile listening history writer and the replay-heatmap tracker.
    /// Delivered as one value because the designated initializer sits at the
    /// SwiftLint body-length ceiling; reach them through ``playEventRecorder`` and
    /// ``playSegmentTracker``.
    @ObservationIgnored public let playHooks: PlayHooks
    /// Folds aged play events into monthly rollups (v15 `playEventRollup`). Started by
    /// ``finishWiring``; `lazy` costs the body-length-capped initializer no line.
    @ObservationIgnored public private(set) lazy var playEventCompactionTrigger =
        PlayEventCompactionTrigger(compactor: PlayEventCompactor(database))
    /// The active-profile session state machine (the single instance per process).
    /// Scoped view models read their `activeProfileId` from its `activeProfile`.
    @ObservationIgnored public let profileService: any ProfileManaging
    /// The resumable, bounded-memory library importer.
    @ObservationIgnored public let scanner: any LibraryScanning
    /// Watches the chosen roots and coordinates re-scan + availability reconcile;
    /// `start()`/`reconcileAll()` at launch, `updateRoots(_:)` when roots change.
    @ObservationIgnored public let watchService: LibraryWatchService
    /// The folder-access flow (`NSOpenPanel`) behind the "Add Folder…" toolbar
    /// button, the empty-state CTA, and the Library pane; retargets `watchService`.
    @ObservationIgnored public let libraryAccess: LibraryAccessController
    /// The active-profile-scoped library roots store (GRDB-backed). A profile
    /// switch assigns `rootsStore.activeProfileId` then retargets `watchService`;
    /// it is the single instance shared by `libraryAccess`, `watchService` and the
    /// sidebar refresh (`MainWindowView.refreshFolders`).
    @ObservationIgnored public let rootsStore: GRDBLibraryRootsStore
    /// Single owner of roots-change scanning, projections, revision signaling and feedback.
    @ObservationIgnored public let libraryFolders: LibraryFolderCoordinator
    /// Keeps `MPNowPlayingInfoCenter` in sync with the transport.
    @ObservationIgnored public let nowPlaying: NowPlayingService
    /// Applies ReplayGain to the engine's global gain on track change.
    @ObservationIgnored public let replayGain: ReplayGainService
    /// Routes media keys / Control Center commands to the coordinator.
    @ObservationIgnored public let remoteCommands: RemoteCommandHandler
    /// Slides in ephemeral feedback toasts (add to playlist, queue, etc).
    public let toast = ToastManager()
    /// The migrated application database (build repositories from this).
    @ObservationIgnored public let database: AppDatabase
    /// The playback engine the transport + EQ drive.
    @ObservationIgnored public let engine: any PlaybackEngine
    /// The app's ONE output-device router: the single `CoreAudioOutputDeviceService`,
    /// the HAL change seam it owns, and the Output preferences pane's picker state.
    /// It outlives that pane deliberately — a replug must re-route playback whether or
    /// not Settings is open. Wired by ``connectOutputRouting(settings:)``.
    @ObservationIgnored private(set) lazy var outputRouting = OutputRoutingModel(
        controller: CoreAudioOutputDeviceService(),
        engine: { [weak self] in self?.engine }
    )
    /// The crossfeed stage's user-facing state and the seam that programmes it. Holds
    /// its own `UserDefaults` scalars rather than a slice of `AppSettings` — reasoning
    /// in `CrossfeedPreferences.swift`. Wired by ``connectCrossfeed()``.
    @ObservationIgnored private(set) lazy var crossfeed = CrossfeedSettingsModel(
        engine: { [weak self] in self?.engine }
    )
    /// Async cover-art resolver for album/artist grids.
    @ObservationIgnored public let artworkProvider: any ArtworkProviding
    /// Resolves missing tags from an online database (MusicBrainz) for the tag
    /// editor's "Auto-fill" action.
    @ObservationIgnored public let metadataFetcher: any OnlineMetadataFetching
    /// Background, pausable auto-enrichment of imported tracks (metadata + lyrics).
    @ObservationIgnored public let enrichment: EnrichmentService
    /// Observable projection of ``enrichment`` for the enrichment progress UI.
    @ObservationIgnored public let enrichmentViewModel: EnrichmentViewModel
    /// Resolves + caches narrative artist/album/track info (MusicBrainz + Wikipedia).
    @ObservationIgnored public let infoService: InfoService
    /// Fills the lyrics cache from embedded tags + `.lrc` sidecars once per launch,
    /// strictly offline. Started after the initial library load in ``finishWiring``.
    @ObservationIgnored public let lyricsSweep: any LyricsSweeping
    /// On-demand background pre-separation of requested tracks so a karaoke toggle feels
    /// instant. `nil` when no separation model is bundled (App Store / CI / fresh clone).
    @ObservationIgnored public let karaokeRender: KaraokeRenderService?
    /// The shared instrumental cache, or `nil` when no separation model is bundled.
    /// Exposed so destructive UI (the ready list's "Remove Karaoke Version") can delete a
    /// rendered instrumental; every read/write is `async` (it is an actor).
    @ObservationIgnored public let karaokeCache: (any InstrumentalCaching)?
    /// The in-memory index of which library tracks have a ready cached instrumental,
    /// plus per-track render progress for the karaoke row rings. A transient projection
    /// of the cache change-seam, rebuilt each launch; the karaoke row UI (Todos 12 & 14)
    /// and the player button (via ``connectKaraoke(stack:settings:cacheDirectoryBox:qualityBox:)``)
    /// read it.
    @ObservationIgnored public let karaokeReadyStore: KaraokeReadyStore
    @ObservationIgnored public let karaokeReadyBadge: KaraokeReadyBadgeModel
    /// The in-memory projection of the live karaoke render queue (in-flight + pending
    /// items, paused flag, current progress) driving the Karaoke Queue sidebar section.
    /// A transient projection of the render service's `onQueueChanged`/`onProgress`
    /// seams (wired in ``connectKaraoke(stack:settings:cacheDirectoryBox:qualityBox:)``),
    /// rebuilt each launch; never persisted.
    @ObservationIgnored public let karaokeQueueStore: KaraokeQueueStore
    /// Posts the "karaoke version ready" system notification when a render finishes,
    /// alongside the in-app completion toast. Requests permission lazily on first use
    /// and degrades to toast-only when denied. Retained for the app's lifetime.
    @ObservationIgnored let karaokeNotifications = KaraokeNotificationCenter()
    /// The local-AI object graph, or `nil` while the Intelligence master toggle is
    /// off. Observable (not `@ObservationIgnored`) so a surface that offers an AI
    /// affordance disappears the moment the graph is torn down. Assigned ONLY by
    /// ``rebuildAI(settings:)`` (a sibling-file extension, so `private(set)` is not
    /// available); treat it as read-only everywhere else.
    var intelligence: AIStack?
    /// The seam an assistant tool reaches the player through. Outlives every AI
    /// graph rebuild, exactly as the coordinator it wraps does.
    @ObservationIgnored private(set) lazy var playbackControl = PlaybackControlWitness.over(self)
    /// Whether an external MCP client may currently control playback — see
    /// `AppEnvironment+MCP.swift`.
    @ObservationIgnored var externalControlGranted = false
    /// The loopback MCP server. OFF by default, its own disclosure, and it
    /// deliberately OUTLIVES ``intelligence`` — reasoning in `AppEnvironment+MCP.swift`.
    @ObservationIgnored private(set) lazy var externalAccess = MCPExternalAccessModel(
        toolbox: { [weak self] in await self?.currentExternalToolbox }
    )
    /// The CLIENT half: the tools the listener's own MCP servers publish. Outlives
    /// ``intelligence`` exactly as ``externalAccess`` does, and is assigned ONLY by
    /// `AppEnvironment+MCPTools.swift` — read-only everywhere else.
    @ObservationIgnored var mcpTools: MCPToolSupply?
    /// Whether ≥1 karaoke render has SUCCEEDED since the render queue last became
    /// non-empty. Set in the render `onFinished` success path and reset when the queue
    /// drains, so the "all versions finished" toast fires only on a drain that actually
    /// produced something — never on a cancel/remove/failure-only drain.
    @ObservationIgnored var karaokeQueueHadSuccessfulRender = false
    /// The serial YouTube download queue. `nil` until the composition root builds it,
    /// which is what makes the quit path safe during the splash. Held as the PROTOCOL
    /// so `AppEnvironment` never depends on the conformer, and read by exactly one
    /// place: ``makeTerminationFlush(_:)``, which cancels it so a spawned yt-dlp is not
    /// reparented to launchd and left running after the app is gone.
    @ObservationIgnored public var downloads: (any DownloadQueueing)?
    /// The Downloads pane's projection + intents, assigned by `connectDownloadsUI(_:)`
    /// alongside ``downloads``. Owns its own `DownloadQueueStore`, which the pane's
    /// progress leaf reads directly.
    @ObservationIgnored public var downloadsModel: DownloadsViewModel?
    /// Advances after a download attempt has been committed to History.
    var downloadHistoryRevision = 0
    /// Memory-only poster frames for the queue rows, built beside ``downloadsModel``.
    @ObservationIgnored var downloadThumbnails: DownloadThumbnailStore?
    /// The engine provisioner, held as the PROTOCOL and read by exactly one surface:
    /// the Downloads preferences pane's version row and update buttons.
    @ObservationIgnored public var downloadTools: (any DownloadToolProviding)?
    /// The loudness pass projection and the ReplayGain tag-write path. `lazy`
    /// because the pass is opt-in; reaching it never STARTS one — only an
    /// explicit user action does.
    @ObservationIgnored private(set) lazy var loudness = LoudnessStack.live(database: database)
    /// The FLAC-checksum and spectral seams behind the "Verify Files…" report.
    /// `lazy` for the same reason ``loudness`` is — and, like it, reaching this
    /// property VERIFIES nothing: only the report sheet's own task does.
    @ObservationIgnored private(set) lazy var integrity = IntegrityStack.live()
    /// The parametric-EQ editor, shared by the EQ panel's mode toggle and the
    /// Equalizer preferences pane so both surfaces read one bank and one mode.
    ///
    /// `lazy` for the same reason ``loudness`` is: a launch that never opens either
    /// surface builds no preset store. It deliberately does NOT replace
    /// ``equalizer`` — the graphic and parametric stages are independent nodes in
    /// different processing slots, and selecting Graphic detaches this one rather
    /// than touching the ten band gains.
    @ObservationIgnored private(set) lazy var parametricEqualizer = ParametricEQViewModel(
        engine: engine,
        presetStore: GRDBParametricEQPresetStore(database)
    )

    // MARK: Chat-initiated downloads (see `AppEnvironment+ChatDownloads.swift`)

    /// Which playlists are waiting on which chat-initiated downloads.
    ///
    /// Declared HERE, on the composition root, rather than on the AI graph: that graph
    /// is rebuilt in place on a toggle flip, a provider change and a profile switch,
    /// and a route closure holding a registry that was replaced underneath it would
    /// claim nothing and silently legacy-import every registered download. Internal
    /// rather than `private` because the sibling-file extension is its only user, and
    /// `private` is scoped to the declaring file.
    @ObservationIgnored let suggestionDownloadRegistry = SuggestionDownloadRegistry()
    /// The proposals a listener discarded, so a chat card can still re-offer one. Held
    /// HERE for the same reason as ``suggestionDownloadRegistry``: the AI graph, and with
    /// it ``ProposalStore``, is rebuilt under the transcript that draws those cards.
    @ObservationIgnored let discardedProposals = DiscardedProposalStore()
    /// Correlates a download row's `UUID` with the video id it was queued for, learned
    /// from `onQueueChanged` and consulted from `onItemProgress`. Same lifetime and the
    /// same reason as ``suggestionDownloadRegistry``.
    @ObservationIgnored let chatDownloadVideoIDMap = DownloadItemVideoIDMap()
    /// The finish-side pipeline: gate, one scan, append or hold.
    ///
    /// Assigned ONLY by ``connectDownloads(settings:)`` (a sibling-file extension, so
    /// `private(set)` is not available); treat it as read-only everywhere else. It
    /// cannot be a `let`: its auto-import dependency is a lock box minted inside that
    /// method, long after `init`.
    @ObservationIgnored var chatAppender: ChatDownloadPlaylistAppender?
    /// The failure half of the same route, driven by the progress seam.
    ///
    /// Assigned ONLY by ``connectDownloads(settings:)``; read-only everywhere else.
    @ObservationIgnored var chatTerminalHandler: ChatDownloadTerminalStateHandler?
    /// Buffers per-track append events into one sentence per playlist.
    ///
    /// Assigned ONLY by ``connectDownloads(settings:)``; read-only everywhere else. It
    /// holds the open window's buffer, so it has to outlive the events it coalesces.
    @ObservationIgnored var chatDownloadToasts: ChatDownloadToastCoalescer?
    /// The tail of the chat-download work chain.
    ///
    /// Both seams that drive this feature are SYNCHRONOUS (`onItemFinished` and
    /// `onItemProgress`) while everything they start is `async`, so each unit is queued
    /// behind its predecessor: without that, a terminal state and the finished route
    /// for the same row could interleave their claims. Assigned ONLY by
    /// ``enqueueChatDownloadWork(_:)``.
    @ObservationIgnored var chatDownloadWork: Task<Void, Never>?
    /// How many units the chain has accepted, so ``drainChatDownloadWork()`` can tell a
    /// settled chain from one that grew while it was being awaited.
    @ObservationIgnored var chatDownloadWorkSequence = 0
    /// What each chat suggestion row's own download is currently saying.
    ///
    /// `lazy` because its one dependency reads ``database``, which exists only once
    /// `init` has run. Declared HERE for the same reason ``suggestionDownloadRegistry``
    /// is: the AI graph is rebuilt on a toggle flip, a provider change and a profile
    /// switch, and a status projection replaced underneath a live download would blank
    /// every row it was still filling in. NEVER PERSISTED — see the store's own header.
    @ObservationIgnored private(set) lazy var chatDownloadStatus = ChatDownloadStatusStore(
        playlistName: Self.chatPlaylistNameLookup(database)
    )
    /// Turns unverified "title + artist" suggestion rows into verified videos.
    ///
    /// A stored closure rather than a direct call to
    /// ``makeYouTubeLinkResolver()`` so a composition suite can drive the whole
    /// download-time resolution path without a network round-trip. Assigned only by
    /// tests; production reads the default.
    @ObservationIgnored
    var resolveChatCandidates: ([YouTubeLinkResolver.Request]) async -> [YouTubeLinkResolver.ResolvedVideo?] =
        AppEnvironment.liveChatCandidateResolution
    /// How many candidates this session has already sent to the lookup provider, against
    /// ``maxChatResolutionsPerSession``. ``makeYouTubeLinkResolver()`` mints a FRESH
    /// value per call and so carries no cap state of its own; this is the whole budget.
    @ObservationIgnored var chatResolutionCount = 0
    /// The tail of the chat-RESOLUTION chain.
    ///
    /// Deliberately a second chain rather than ``chatDownloadWork``: a batch lookup owns
    /// a 30-second deadline, and running it in the chain that carries playlist appends
    /// would delay a finished download's append by that long. Assigned ONLY by
    /// ``resolveAndEnqueue(_:appendTarget:appendProfileId:)``.
    @ObservationIgnored var chatResolutionWork: Task<Void, Never>?
    /// The video id the unit currently running on the chat-download chain is about.
    ///
    /// ``ChatDownloadAppendEvent`` names no download, so the announcement fan-out has no
    /// other way to address the status row an event belongs to. Safe as a single slot
    /// precisely because that chain is STRICTLY serial — one unit at a time, never
    /// nested — and every unit that can announce installs it through
    /// ``announcingChatDownloads(as:_:)``.
    @ObservationIgnored var chatAnnouncingVideoID: String?

    func recordPlaybackSource(_ source: PlaybackSource?) {
        currentSource = source
    }

    init(_ dependencies: Dependencies) {
        let database = dependencies.database
        self.database = database
        scanner = dependencies.scanner
        watchService = dependencies.watchService
        libraryAccess = dependencies.libraryAccess
        rootsStore = dependencies.rootsStore

        profileService = dependencies.profileService
        let profileId = dependencies.profileService.activeProfile.id ?? ProfileRecord.guestID

        let trackRepository = TrackRepository(database)

        engine = dependencies.engine
        let coordinator = Self.makeCoordinator(dependencies)
        self.coordinator = coordinator
        karaokeRender = Self.makeKaraokeRender(dependencies.karaoke)
        karaokeCache = dependencies.karaoke.cache
        karaokeReadyStore = KaraokeReadyStore()
        karaokeReadyBadge = KaraokeReadyBadgeModel(readyStore: karaokeReadyStore, repository: trackRepository)
        karaokeQueueStore = KaraokeQueueStore()
        playHooks = Self.makePlayHooks(coordinator, dependencies)
        nowPlaying = NowPlayingService(snapshotWriter: dependencies.snapshotWriter)
        replayGain = Self.makeReplayGain(dependencies, database: database)
        artworkProvider = dependencies.artworkProvider
        metadataFetcher = dependencies.metadataFetcher
        infoService = dependencies.infoService
        lyricsSweep = LyricsSweepService(database: database, lyricsProvider: dependencies.lyricsProvider)
        remoteCommands = Self.makeRemoteCommands(coordinator: coordinator)

        library = Self.makeLibraryViewModel(database: database, repository: trackRepository, profileId: profileId)
        search = SearchViewModel(repository: trackRepository, activeProfileId: profileId)
        player = PlayerViewModel(coordinator: coordinator, artworkProvider: dependencies.artworkProvider)
        queue = QueueViewModel(coordinator: coordinator)
        equalizer = EQViewModel(engine: dependencies.engine, presetStore: dependencies.presetStore)
        visualizer = VisualizerViewModel(source: dependencies.spectrumSource)
        lyrics = LyricsViewModel(provider: dependencies.lyricsProvider)
        lyricsBrowser = Self.makeLyricsBrowser(dependencies, profileId: profileId)
        playlists = PlaylistViewModel(repository: PlaylistRepository(database), activeProfileId: profileId)
        playlistImportExport = PlaylistImportExportViewModel(
            playlistIO: PlaylistFileIO(database),
            repository: PlaylistRepository(database)
        )

        let enrichmentGraph = Self.makeEnrichment(dependencies, database: database)
        enrichment = enrichmentGraph.service
        enrichmentViewModel = enrichmentGraph.viewModel
        libraryFolders = Self.makeLibraryFolders(dependencies, repository: trackRepository, toast: toast)
        Self.finishWiring(
            self,
            coordinator: coordinator,
            engine: dependencies.engine,
            nowPlaying: nowPlaying,
            karaokeCache: karaokeCache
        )
    }
}

// `Dependencies` lives in `AppEnvironment+Composition.swift`, for the file-length
// reason that file's own header states.
