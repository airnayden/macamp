// AppEnvironment+Composition — shared object-graph wiring helpers.
//
// Split out of `AppEnvironment.swift` to keep that composition-root file under the
// SwiftLint `file_length` budget, mirroring the macOS shell. These static helpers
// are the heavy wiring the designated initializer runs: the enrichment service, the
// play-capture consumers, and the now-playing mirror.
import AudioEngine
import Foundation
import Metadata
import Models
import Persistence
import Services
import ViewModels

/// The two play-capture consumers ``AppEnvironment/makePlayHooks(_:_:)`` builds and
/// wires together. One value so the composition root pays for one assignment.
struct PlayHooks {
    let recorder: PlayEventRecorder
    let tracker: PlaySegmentTracker
}

extension AppEnvironment {
    /// Builds the enrichment service (sharing the `metadataFetcher`'s rate limiter
    /// and the `lyricsProvider`) plus its observable projection.
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
        return (service, EnrichmentViewModel(service: service))
    }

    static func makeRemoteCommands(coordinator: PlaybackCoordinator) -> RemoteCommandHandler {
        let handler = RemoteCommandHandler(coordinator: coordinator)
        handler.activate()
        return handler
    }

    /// Builds the play-capture consumers and wires them to the coordinator's hooks.
    ///
    /// iOS is Guest-fixed (no profile UI), so attribution never changes in practice —
    /// the start hook is wired anyway so the capture semantics stay identical to
    /// macOS when profiles do reach this shell. Each hook is a SINGLE closure slot,
    /// so this is the ONE place that assigns them, dispatching recorder then tracker.
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
        let tracker = PlaySegmentTracker(
            heat: PlaySegmentHeatRepository(database),
            tracks: TrackRepository(database),
            playhead: PlaySegmentPlayhead(
                currentTrack: { [weak coordinator] in coordinator?.current },
                currentTime: { [weak coordinator] in coordinator?.currentTime ?? 0 },
                activeProfileId: activeProfileId
            )
        )
        coordinator.onTrackStarted = { [weak coordinator] _ in
            recorder.trackDidStart()
            if let track = coordinator?.current {
                tracker.beginTrack(trackRef: track, profileId: activeProfileId())
            }
        }
        coordinator.onPlayEvent = {
            recorder.record($0)
            tracker.flush(signal: $0)
        }
        coordinator.onSeek = { tracker.noteSeek(from: $0, to: $1) }
        return PlayHooks(recorder: recorder, tracker: tracker)
    }

    /// Chains both playback observers onto the coordinator's single-owner
    /// `stateDidChange` slot, in one call because the designated initializer has no
    /// room for a second statement.
    static func wirePlaybackFeeds(
        _ coordinator: PlaybackCoordinator,
        engine: any PlaybackEngine,
        nowPlaying: NowPlayingService,
        hooks: PlayHooks
    ) {
        wireNowPlayingFeed(coordinator: coordinator, engine: engine, service: nowPlaying)
        let previous = coordinator.stateDidChange
        coordinator.stateDidChange = { state in
            previous?(state)
            hooks.tracker.playbackStateDidChange(isPlaying: state.playback == .playing)
        }
    }

    /// Chains the now-playing feed AFTER ``PlayerViewModel`` claims the
    /// coordinator's single `stateDidChange` slot in its `init`, calling the
    /// previous handler first so both run. This is the iOS track-identity feed
    /// (`updateTrack`) that was previously absent — without it the lock screen
    /// stayed titleless. Album/artwork are `nil` (parity with macOS; a deferral).
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
}
