// AppEnvironment+Composition — shared object-graph wiring helpers.
//
// Split out of `AppEnvironment.swift` to keep that composition-root file under the
// SwiftLint `file_length` budget. These static helpers are the heavy, shared wiring
// the designated initializer runs identically for both the live and preview graphs:
// building the enrichment service, the play-count/listened hooks, and the
// now-playing mirror — plus the composition VALUE TYPES the root is assembled
// from, which live here for the same budget reason.
import AIConnectorKit
import Artwork
import AudioEngine
import DSP
import Foundation
import Lyrics
import Metadata
import Models
import Persistence
import Separation
import Services
import ViewModels
import Visualizer

/// The two play-capture consumers ``AppEnvironment/makePlayHooks(_:_:)`` builds and
/// wires together. One value so the composition root pays for one assignment.
public struct PlayHooks {
    public let recorder: PlayEventRecorder
    public let tracker: PlaySegmentTracker
}

public extension AppEnvironment {
    /// Writes the per-profile listening history (v15 `playEvent`). Attribution is
    /// captured when a track starts, so a profile switch mid-track still files the
    /// interrupted play under the profile that was listening to it.
    var playEventRecorder: PlayEventRecorder {
        playHooks.recorder
    }

    /// Captures which PARTS of a track get replayed (v15 `playSegmentHeat`).
    var playSegmentTracker: PlaySegmentTracker {
        playHooks.tracker
    }
}

extension AppEnvironment {
    /// Builds the enrichment service (sharing the `metadataFetcher`'s rate limiter,
    /// the `lyricsProvider`, and the `infoService`) plus its observable projection.
    ///
    /// The projection also gets the coverage reader, so the idle status reports what
    /// the library actually holds instead of assuming a library nobody has enriched
    /// is up to date. The profile id is a closure read at refresh time, which is why
    /// the switch orchestrator needs no entry for this view model.
    static func makeEnrichment(
        _ dependencies: Dependencies,
        database: AppDatabase
    ) -> (service: EnrichmentService, viewModel: EnrichmentViewModel) {
        let service = EnrichmentService(
            database: database,
            metadataFetcher: dependencies.metadataFetcher,
            metadataWriter: SFBMetadataWriter(),
            lyricsProvider: dependencies.lyricsProvider,
            infoService: dependencies.infoService
        )
        let profileService = dependencies.profileService
        let viewModel = EnrichmentViewModel(
            service: service,
            reader: EnrichmentCoverageReader(database),
            activeProfileId: { profileService.activeProfile.id ?? ProfileRecord.guestID }
        )
        return (service, viewModel)
    }

    /// Installs every playback-progress hook and returns the play-capture consumers.
    ///
    /// Wiring and construction are fused because ``AppEnvironment/init(_:)`` sits
    /// exactly at the SwiftLint `function_body_length` ceiling: returning both
    /// consumers from the call that already had to be there costs it no new line.
    ///
    /// Each coordinator hook is a SINGLE closure slot, so this is the ONE place that
    /// assigns them — a second assignment anywhere would silently clobber this one.
    /// Fan-out order inside each closure is fixed: recorder, then tracker, then the
    /// library counters (which are gated behind `trackId > 0`, so they must run last
    /// for the two stats consumers to see non-library plays too).
    static func makePlayHooks(
        _ coordinator: PlaybackCoordinator,
        _ dependencies: Dependencies
    ) -> PlayHooks {
        let database = dependencies.database
        let profileService = dependencies.profileService
        let activeProfileId: @MainActor () -> Int64 = {
            profileService.activeProfile.id ?? ProfileRecord.guestID
        }
        let recorder = PlayEventRecorder(
            events: PlayEventRepository(database),
            tracks: TrackRepository(database),
            activeProfileId: activeProfileId
        )
        let tracker = makeSegmentTracker(coordinator, database: database, activeProfileId: activeProfileId)
        coordinator.onTrackStarted = { [weak coordinator] trackId in
            // Ahead of the `trackId > 0` filter: a non-library play is still
            // attributed to whoever started it, it just increments no counters.
            recorder.trackDidStart()
            // The hook carries only an id; the heatmap needs the duration and the
            // display identity, and the hook fires post-mutation so `current` is
            // already the incoming track.
            if let track = coordinator?.current {
                tracker.beginTrack(trackRef: track, profileId: activeProfileId())
            }
            guard trackId > 0 else { return }
            let repo = TrackRepository(database)
            Task { try? await repo.incrementPlayCount(profileId: activeProfileId(), trackId: trackId) }
        }
        coordinator.onTrackPlayed = { trackId in
            guard trackId > 0 else { return }
        }
        coordinator.onTrackListened = { trackId in
            guard trackId > 0 else { return }
            let repo = TrackRepository(database)
            Task { try? await repo.incrementListenedCount(profileId: activeProfileId(), trackId: trackId) }
        }
        coordinator.onPlayEvent = {
            recorder.record($0)
            tracker.flush(signal: $0)
        }
        coordinator.onSeek = { tracker.noteSeek(from: $0, to: $1) }
        return PlayHooks(recorder: recorder, tracker: tracker)
    }

    /// The replay-heatmap capture side of ``makePlayHooks(_:_:)``.
    ///
    /// Weak coordinator captures throughout: the tracker outlives no one, but the
    /// coordinator holds the hooks that hold the tracker.
    static func makeSegmentTracker(
        _ coordinator: PlaybackCoordinator,
        database: AppDatabase,
        activeProfileId: @escaping @MainActor () -> Int64
    ) -> PlaySegmentTracker {
        PlaySegmentTracker(
            heat: PlaySegmentHeatRepository(database),
            tracks: TrackRepository(database),
            playhead: PlaySegmentPlayhead(
                currentTrack: { [weak coordinator] in coordinator?.current },
                currentTime: { [weak coordinator] in coordinator?.currentTime ?? 0 },
                activeProfileId: activeProfileId
            )
        )
    }

    /// The work a Quit must not lose: the play in flight, its replay heatmap, and
    /// the resume position — plus the one thing a Quit must actively STOP.
    ///
    /// `flushForTermination()` is synchronous — it only emits the outgoing signal,
    /// which the recorder turns into an enqueued write and the tracker into an
    /// enqueued merge — so all three awaits below must follow it, in this order, for
    /// that final pass to be covered.
    ///
    /// The download queue is cancelled FIRST and synchronously. A `Process` this app
    /// spawned does not die with it: on macOS an orphaned child is reparented to
    /// launchd and keeps running — keeps writing into the staging directory and
    /// keeps using the network — long after the app is gone. `cancelAll()` signals
    /// it while there is still a process to signal. It runs ahead of the awaits so a
    /// slow database flush (or the timeout that bounds it) cannot leave the signal
    /// unsent; nothing below reads the queue, so the ordering costs the flush
    /// nothing.
    static func makeTerminationFlush(_ environment: AppEnvironment) -> @MainActor () async -> Void {
        { [weak environment] in
            guard let environment else { return }
            environment.downloads?.cancelAll()
            environment.coordinator.flushForTermination()
            await environment.playEventRecorder.flushAndWait()
            await environment.playSegmentTracker.flushAndWait()
            await environment.playbackStatePersister.flushAtTermination()
        }
    }

    static func makeRemoteCommands(coordinator: PlaybackCoordinator) -> RemoteCommandHandler {
        let handler = RemoteCommandHandler(coordinator: coordinator)
        handler.activate()
        return handler
    }

    static func makeLibraryFolders(
        _ dependencies: Dependencies,
        repository: TrackRepository,
        toast: ToastManager
    ) -> LibraryFolderCoordinator {
        let profileService = dependencies.profileService
        return LibraryFolderCoordinator(
            access: dependencies.libraryAccess,
            scanner: dependencies.scanner,
            watchService: dependencies.watchService,
            sidebar: FolderSidebarViewModel(
                repository: repository,
                persistence: FolderTreeStore().persistence
            ),
            toast: toast,
            activeProfileId: { profileService.activeProfile.id ?? ProfileRecord.guestID }
        )
    }

    static func makeLibraryViewModel(
        database: AppDatabase,
        repository: TrackRepository,
        profileId: Int64
    ) -> LibraryViewModel {
        LibraryViewModel(
            trackRepository: repository,
            albumRepository: AlbumRepository(database),
            artistRepository: ArtistRepository(database),
            databaseReader: database.writer,
            activeProfileId: profileId
        )
    }

    static func makeLyricsBrowser(_ dependencies: Dependencies, profileId: Int64) -> LyricsBrowserViewModel {
        LyricsBrowserViewModel(
            repository: LyricsBrowseRepository(dependencies.database),
            provider: dependencies.lyricsProvider,
            activeProfileId: profileId
        )
    }

    /// Chains the now-playing mirror AFTER ``PlayerViewModel`` claims the
    /// coordinator's single `stateDidChange` slot in its `init`, calling the
    /// previous handler first so both the player UI and the now-playing mirror
    /// run on every state change (assigning here alone would be clobbered).
    static func wireNowPlayingFeed(
        coordinator: PlaybackCoordinator,
        engine: any PlaybackEngine,
        service: NowPlayingService
    ) {
        let previous = coordinator.stateDidChange
        coordinator.stateDidChange = { [weak coordinator] state in
            previous?(state)
            guard let coordinator else { return }
            if let track = coordinator.current {
                service.updateTrack(NowPlayingMetadata(
                    title: track.title ?? URL(fileURLWithPath: track.filePath).lastPathComponent,
                    artist: track.artist,
                    album: nil,
                    duration: track.duration ?? 0,
                    artworkRef: nil
                ))
            } else {
                service.updateTrack(nil)
            }
            let engineState = engine.state
            service.updatePlayback(PlaybackStatus(
                isPlaying: engineState == .playing,
                elapsed: coordinator.currentTime,
                rate: engineState == .playing ? 1 : 0
            ))
        }
    }

    /// Chains the 1 Hz playhead sampler's start/stop onto the same single-owner
    /// `stateDidChange` slot, after everything already claiming it. Sampling exists
    /// only between these two transitions, so a paused app schedules no timer at all.
    static func wireSegmentSampling(coordinator: PlaybackCoordinator, tracker: PlaySegmentTracker) {
        let previous = coordinator.stateDidChange
        coordinator.stateDidChange = { state in
            previous?(state)
            tracker.playbackStateDidChange(isPlaying: state.playback == .playing)
        }
    }

    /// Routes the sweep's cache writes into the lyrics browser.
    ///
    /// Must be set before the first ``LyricsSweeping/start()``: the pass captures
    /// the handler when it is built, so a later assignment misses that pass.
    static func wireLyricsSweep(_ environment: AppEnvironment) {
        environment.lyricsSweep.onDidCacheLyrics = { [weak environment] in
            Task { @MainActor in environment?.lyricsBrowser.cacheDidChange() }
        }
    }

    static func finishWiring(
        _ environment: AppEnvironment,
        coordinator: PlaybackCoordinator,
        engine: any PlaybackEngine,
        nowPlaying: NowPlayingService,
        karaokeCache: (any InstrumentalCaching)?
    ) {
        wireLyricsSweep(environment)
        environment.libraryFolders.connect { [weak environment, karaokeCache] in
            guard let environment else { return }
            try? await environment.library.loadInitialTracks()
            if let karaokeCache { await environment.resyncKaraokeReadyStore(from: karaokeCache) }
            // Fires on every roots refresh; the service runs one pass at a time, so a
            // refresh that follows a finished pass sweeps newly scanned tracks too.
            //
            // Gated because at launch this closure runs while the catch-up scan is
            // still walking the roots, and the sweep opens every file it probes. The
            // catch-up sequence owns that first pass; only LATER refreshes re-arm here.
            if environment.libraryFolders.launchCatchUpComplete {
                environment.lyricsSweep.start()
            }
        }
        coordinator.playbackSourceDidChange = { [weak environment] in environment?.recordPlaybackSource($0) }
        wireNowPlayingFeed(coordinator: coordinator, engine: engine, service: nowPlaying)
        wireSegmentSampling(coordinator: coordinator, tracker: environment.playSegmentTracker)
        wireReplayGain(environment, coordinator: coordinator)
        _ = environment.playbackStatePersister
        environment.playEventCompactionTrigger.start()
        wireProfileSwitch(environment: environment)
    }

    /// The one door every AI mutation goes through, built fresh.
    ///
    /// Extracted from ``makeAI`` for SwiftLint's `function_body_length` ceiling,
    /// exactly as ``makeAudioAnalysis(database:)`` was. The construction is
    /// unchanged.
    static func makeAssistant(
        settings: AppSettings,
        database: AppDatabase,
        proposals: ProposalStore,
        backends: AssistantBackendStack,
        mixGenerator: MixGeneratorService
    ) -> AssistantViewModel {
        AssistantViewModel(
            proposals: proposals,
            backends: backends,
            repositories: AssistantRepositoryStack(
                playlists: PlaylistRepository(database),
                smartPlaylists: SmartPlaylistRepository(database),
                mixGenerator: mixGenerator,
                metadataWriter: SFBMetadataWriter(),
                selfWriteRegistry: nil
            ),
            availabilityProbe: AIFeatureGate.availabilityProbe(for: .nlCreation, settings: settings)
        )
    }
}

// MARK: - Composition value types

extension AppEnvironment {
    /// The leaf dependencies that distinguish a live environment from a preview
    /// one. Bundled into one value so the designated initializer takes a single
    /// parameter while the heavy wiring stays shared.
    struct Dependencies {
        var database: AppDatabase
        var engine: any PlaybackEngine
        var artworkProvider: any ArtworkProviding
        var metadataFetcher: any OnlineMetadataFetching
        var infoService: InfoService
        var lyricsProvider: any LyricsProviding
        var presetStore: any EQPresetStoring
        var spectrumSource: any SpectrumSource
        var scanner: any LibraryScanning
        var watchService: LibraryWatchService
        var libraryAccess: LibraryAccessController
        var snapshotWriter: (any SnapshotWriting)?
        var profileService: any ProfileManaging
        var rootsStore: GRDBLibraryRootsStore
        var karaoke: KaraokeStack
        var randomNumberGenerator: any RandomNumberGenerator = SystemRandomNumberGenerator()
    }

    /// The two seams the AI graph is built OVER rather than owns.
    ///
    /// A value type for the reason ``ConnectorContext`` is one: without it ``makeAI``
    /// sits at six arguments, past SwiftLint's `function_parameter_count` ceiling.
    /// They really are one thing — what OUTLIVES every graph rebuild, and is
    /// therefore handed in rather than constructed there.
    struct AIStackSeams {
        /// The seam a control tool reaches the player through. Outlives the graph
        /// exactly as the coordinator it wraps does — see
        /// `AppEnvironment.playbackControl`. Whether a given toolbox is granted it
        /// is decided per caller.
        let playback: any ToolboxPlaybackControlling
        /// The listener's own MCP servers' tools, read at engine-mint time. Outlives
        /// the graph because a connection owns a CHILD PROCESS, and a graph rebuilt
        /// on a model change would terminate and respawn one for a reason that has
        /// nothing to do with it — see `AppEnvironment+MCPTools.swift`.
        let externalTools: @MainActor () -> [AITool]

        /// This build's connector route, carrying the external tools along with it.
        func connectorContext(
            registry: ConnectorRegistry,
            session: ConnectorSession
        ) -> ConnectorContext {
            ConnectorContext(registry: registry, session: session, externalTools: externalTools)
        }
    }
}
