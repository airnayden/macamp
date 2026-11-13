// AppEnvironment+ReplayGain — the wiring that makes a measured loudness audible.
//
// The macOS shell's `AppEnvironment+ReplayGain.swift` verbatim in shape, for the same
// reason `makePlayHooks` and `wireNowPlayingFeed` are duplicated rather than shared:
// the two composition roots are shell code, and PlayerCore owns no shell.
//
// `ReplayGainService` was CONSTRUCTED here and CALLED by nothing — no `apply`, no
// `reapply`, no mode push — so the three-rung fallback (file tags -> the v18
// `trackLoudness` cache -> unity) reached `eq.globalGain` never.
//
// ── WHY `stateDidChange`, NOT `onTrackStarted` ────────────────────────────────
//
// `onTrackStarted` fires from `loadActivated` alone, so it misses a manual-queue
// track (`activateManual`) and a restored one. The coordinator's published `current`
// changes on every one of them, and it is already the slot the now-playing mirror
// chains onto — so this reads `previous` and calls it first, exactly as that does.
//
// ── WHY THE PERSISTED COLUMNS, NOT A FILE READ ────────────────────────────────
//
// The scanner already read the file's REPLAYGAIN_* tags into `track.replaygain*`.
// Re-reading the file per track change would re-parse every tag AND pull every
// embedded picture into memory (`SFBMetadataReader` carries artwork bytes verbatim).
//
// ── KNOWN GAP, PRE-EXISTING AND NOT INTRODUCED HERE ───────────────────────────
//
// This shell has no startup-defaults push at all — `AppSettings.defaultEQPresetName`
// is not applied at launch either — so the persisted `replayGainMode` only reaches
// the service once a picker writes `EQViewModel.replayGainMode`. The mode is read at
// every apply below, so the moment that push exists this wiring honours it with no
// further change.
import AudioEngine
import Foundation
import GRDB
import Metadata
import Observation
import Persistence
import Services

extension AppEnvironment {
    /// The ReplayGain service, holding the analysis cache rung 2 reads.
    static func makeReplayGain(engine: any PlaybackEngine, database: AppDatabase) -> ReplayGainService {
        ReplayGainService(engine: engine, loudnessCache: TrackLoudnessRepository(database))
    }

    /// Installs both halves of the ReplayGain playback path: the per-track apply and
    /// the mode follow.
    ///
    /// The applier is retained by the closure this chains onto the coordinator, so it
    /// lives exactly as long as the coordinator does and needs no stored property.
    static func wireReplayGain(_ environment: AppEnvironment, coordinator: PlaybackCoordinator) {
        let applier = ReplayGainTrackApplier(
            service: environment.replayGain,
            mode: { [weak environment] in environment?.equalizer.replayGainMode ?? .off },
            tags: ReplayGainTrackApplier.persistedTags(database: environment.database)
        )
        let previous = coordinator.stateDidChange
        coordinator.stateDidChange = { state in
            previous?(state)
            applier.trackDidChange(to: state.current)
        }
        environment.observeReplayGainMode()
    }

    /// Re-pushes the gain whenever the listener picks a different ReplayGain mode.
    ///
    /// `onChange` fires BEFORE the write lands, so the hop to the main actor is what
    /// makes the read below see the new value, and the tail call re-arms the one-shot
    /// observation.
    private func observeReplayGainMode() {
        withObservationTracking {
            _ = equalizer.replayGainMode
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.replayGain.mode = self.equalizer.replayGainMode
                self.replayGain.reapply()
                self.observeReplayGainMode()
            }
        }
    }
}

// MARK: - ReplayGainTrackApplier

/// Resolves and applies the ReplayGain summand for whatever the coordinator is
/// playing — on the main actor, at track change, NEVER from the tap or the render
/// callback (rung 2 is a database read; the render thread allocates nothing).
@MainActor
final class ReplayGainTrackApplier {
    /// The persisted REPLAYGAIN_* tags for one library track, or `nil` when the file
    /// carried none — which is exactly what hands the question to rung 2.
    typealias TagSource = @Sendable (Int64) async -> ReplayGain?

    private let service: ReplayGainService
    private let mode: @MainActor () -> ReplayGainMode
    private let tags: TagSource

    /// The ref the latest resolution is about. It is both the "same track, nothing to
    /// do" latch (a pause republishes the same ref) and the staleness check a
    /// resolution that lost a race fails.
    private var currentRefID: UUID?
    private var pending: Task<Void, Never>?

    init(
        service: ReplayGainService,
        mode: @escaping @MainActor () -> ReplayGainMode,
        tags: @escaping TagSource
    ) {
        self.service = service
        self.mode = mode
        self.tags = tags
    }

    /// Applies the gain for `track`, or unity when nothing is playing.
    func trackDidChange(to track: TrackRef?) {
        guard track?.id != currentRefID else { return }
        currentRefID = track?.id
        pending?.cancel()
        pending = nil
        // Read at apply time rather than only on change, so the mode a restored track
        // starts under is the persisted one even if a launch push has not landed.
        service.mode = mode()
        guard let track else {
            service.apply(ReplayGain())
            return
        }
        applyResolved(for: track)
    }

    /// Rung 1 off-main, then the service's own rungs 2 and 3, then the push.
    private func applyResolved(for track: TrackRef) {
        let segment = Self.segment(for: track)
        let trackID = track.trackID
        let refID = track.id
        let tags = tags
        let service = service
        pending = Task { @MainActor [weak self] in
            let resolved = await Self.tags(forTrackID: trackID, using: tags)
            guard let self, !Task.isCancelled, currentRefID == refID else { return }
            await service.apply(metadata: TrackMetadata(replayGain: resolved), segment: segment)
        }
    }

    /// The segment a cached measurement must have been taken over.
    ///
    /// `nil` for anything with no library row — the fallback then stops at rung 1
    /// rather than reading the cache at all. A cue segment carries its own bounds, so
    /// a row measured over a DIFFERENT segment of the same audio file is refused by
    /// `ReplayGainSegment.matches(_:)` instead of being served.
    static func segment(for track: TrackRef) -> ReplayGainSegment? {
        guard let trackID = track.trackID, trackID > 0 else { return nil }
        guard let cueStartFrame = track.cueStartFrame else { return .wholeFile(trackId: trackID) }
        return ReplayGainSegment(
            trackId: trackID,
            cueStartFrame: cueStartFrame,
            cueEndFrame: track.cueEndFrame
        )
    }

    /// Reads `track.replaygain*` off-main — the four numbers the scanner already took
    /// out of the file's own tags.
    static func persistedTags(database: AppDatabase) -> TagSource {
        let writer = database.writer
        return { trackID in
            let record = try? await writer.read { db in
                try TrackRecord.fetchOne(db, key: trackID)
            }
            guard let record else { return nil }
            let tags = ReplayGain(
                trackGain: record.replaygainTrackGain,
                trackPeak: record.replaygainTrackPeak,
                albumGain: record.replaygainAlbumGain,
                albumPeak: record.replaygainAlbumPeak
            )
            return tags.isEmpty ? nil : tags
        }
    }

    private static func tags(forTrackID trackID: Int64?, using source: TagSource) async -> ReplayGain? {
        guard let trackID, trackID > 0 else { return nil }
        return await source(trackID)
    }
}
