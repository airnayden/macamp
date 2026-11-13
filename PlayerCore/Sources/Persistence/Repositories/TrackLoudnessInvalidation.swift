// TrackLoudnessInvalidation — the narrow seam a targeted re-analysis writes through.
//
// "Analyze Loudness" on a selection is the same trick
// `AudioAnalysisService.startFullReanalysis()` plays, narrowed from the whole
// library to a set of ids: DELETE those rows, then run the ordinary pass. With no
// row left, each selected track is stale by the repository's own
// `staleFingerprintClause`, so the unchanged run loop measures it — and, crucially,
// the pass's per-page ALBUM POOLING still runs over it. A targeted analyser that
// wrote rows itself would have to restate both the commit and the pooling, and
// would leave every album it touched un-pooled.
//
// A one-method protocol for ``TrackLoudnessReading``'s reason: the selection action
// performs exactly one kind of write, and injecting the seven-method repository
// protocol would hand it `upsert` / `applyAlbumLoudness` / `deleteAll`. A seam that
// cannot express those writes cannot perform them, and a one-method protocol makes
// a test double a dozen lines rather than seven stubs.
import Foundation
import GRDB

/// Discards cached loudness for named tracks, so the next pass measures them again.
public protocol TrackLoudnessInvalidating: Sendable {
    /// Deletes the `trackLoudness` rows for up to
    /// ``TrackLoudnessRepository/fetchLimit`` track ids.
    ///
    /// Ids with no row are silently unaffected — a track that was never analysed
    /// is already stale, which is the state this call establishes.
    func deleteLoudness(forTrackIds trackIds: [Int64]) async throws
}

extension TrackLoudnessRepository: TrackLoudnessInvalidating {
    /// Bounded by ``fetchLimit`` for the reason every other batch here is: a
    /// selection is user-sized, and an unbounded `IN (…)` list would hand SQLite a
    /// statement whose size is dictated by how long someone held ⌘.
    public func deleteLoudness(forTrackIds trackIds: [Int64]) async throws {
        let capped = Array(trackIds.prefix(Self.fetchLimit))
        guard !capped.isEmpty else { return }
        try await dbWriter.write { db in
            _ = try TrackLoudnessRecord
                .filter(capped.contains(TrackLoudnessRecord.Columns.trackId))
                .deleteAll(db)
        }
    }
}
