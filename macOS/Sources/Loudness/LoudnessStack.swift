// LoudnessStack — the loudness object graph, built on first use.
//
// Two surfaces share one graph: the Playback pane's Loudness section drives
// ``scan``, and the library selection's "Write ReplayGain Tags…" sheet drives
// ``tagWriter``. Both read the same ``TrackLoudnessRepository``, so the coverage
// figure the pane shows and the values the sheet writes can never come from two
// different views of the table.
//
// Built lazily by ``AppEnvironment`` rather than in its initializer: the pass is
// opt-in, and a launch that never opens the pane nor right-clicks a track should
// not construct a decoder provider at all.
import Decoding
import Persistence
import Services
import ViewModels

/// The loudness pass projection plus the ReplayGain tag-write path.
@MainActor
struct LoudnessStack {
    let scan: LoudnessScanViewModel
    let tagWriter: ReplayGainTagWriteModel

    static func live(database: AppDatabase) -> LoudnessStack {
        let repository = TrackLoudnessRepository(database)
        let service = LoudnessScanService(
            database: database,
            scanner: LoudnessScanner(decoderProvider: SFBDecoderProvider())
        )
        return LoudnessStack(
            scan: LoudnessScanViewModel(
                service: service,
                database: database,
                invalidator: repository
            ),
            tagWriter: ReplayGainTagWriteModel(loudness: repository)
        )
    }
}
