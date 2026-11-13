// AppEnvironment+ReplayGain — the wiring that makes a measured loudness audible.
//
// `ReplayGainService` was CONSTRUCTED by both composition roots and CALLED by
// neither: nothing pushed `apply`/`reapply`, and nothing pushed the selected mode.
// The three-rung fallback (file tags -> the v18 `trackLoudness` cache -> unity)
// therefore resolved correctly in its own unit tests and reached `eq.globalGain`
// never, so a tagless-but-analysed library played at unity no matter what the
// Loudness pass had measured. This file is the missing half.
//
// ── WHY `stateDidChange`, NOT `onTrackStarted` ────────────────────────────────
//
// `onTrackStarted` fires from `loadActivated` alone, so it misses a manual-queue
// track (`activateManual`) and a restored one — two paths that start audio with no
// gain decision behind them. The coordinator's published `current` changes on every
// one of them, so the state feed is the complete signal. It is also the slot the
// now-playing mirror and the segment sampler already chain onto, so this follows
// that file's pattern rather than inventing one: read `previous`, call it first.
//
// A karaoke swap reloads the SAME ref, so ``ReplayGainTrackApplier``'s latch leaves
// the gain alone — which is the karaoke ADR's recorded choice (the original track's
// ReplayGain applies to its instrumental).
//
// ── WHY THE PERSISTED COLUMNS, NOT A FILE READ ────────────────────────────────
//
// Rung 1 wants the file's REPLAYGAIN_* tags. The scanner already read them and wrote
// them to `track.replaygain*`; re-reading the file here would re-parse every tag AND
// pull every embedded picture into memory (`SFBMetadataReader` carries artwork bytes
// verbatim) once per track change — precisely the "never a hot path" that reader
// documents. One indexed row read supplies the same four numbers.
//
// ── WHY NO `.onChange` IN THE PREFERENCES PANE ────────────────────────────────
//
// Every ReplayGain picker in this shell — the Preferences pane, the full player, and
// the launch push in `StateRestorationController.applyStartupDefaults()` — writes
// `EQViewModel.replayGainMode` and nothing else. Observing that one property covers
// all three; a pane-local `.onChange` would cover one and leave the other two dead,
// which is the state this file exists to end. Same reasoning
// `IntelligencePreferencesPane` records for the Intelligence master toggle.
import AudioEngine
import Foundation
import GRDB
import Metadata
import Observation
import Persistence
import Services

extension AppEnvironment {
    /// The ReplayGain service, holding the analysis cache rung 2 reads.
    ///
    /// A factory rather than an inline construction because the designated
    /// initializer sits one line under SwiftLint's `function_body_length` ceiling.
    static func makeReplayGain(_ dependencies: Dependencies, database: AppDatabase) -> ReplayGainService {
        ReplayGainService(engine: dependencies.engine, loudnessCache: TrackLoudnessRepository(database))
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
    /// makes the read below see the new value — and the tail call is what re-arms the
    /// one-shot observation, the shape `observeFolderSort(settings:)` uses.
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
    /// do" latch (a karaoke swap or a pause republishes the same ref) and the
    /// staleness check a resolution that lost a race fails.
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
        // starts under is the persisted one even if the launch push has not landed.
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
