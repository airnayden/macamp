// CueSuppression — the "hide a whole-file row a `.cue` sheet superseded" predicate,
// and the EXHAUSTIVE list of the call sites allowed to apply it.
//
// When a `.cue` sheet appears for a file the library had already imported whole, the
// scanner sets `track.cueSuppressed = 1` on the pre-existing row instead of deleting
// it. Deleting would cascade `playlistTrack` / `profileTrackState` /
// `folderTrackOrder` and orphan the bare-`trackId` `playEvent` / `playSegmentHeat`
// rows — forbidden by the never-delete-user-data invariant.
//
// A suppressed row therefore keeps WORKING everywhere it is already referenced: an
// existing playlist entry still resolves and plays, its favourite and its listening
// history are retained. It is hidden only from the two surfaces that would otherwise
// offer the user the same audio twice.
//
// # Why this is NOT composed into `LibraryVisibility`
// `LibraryVisibility.predicate` is the shared profile-scoping fragment that EVERY
// track read flows through. Folding `cueSuppressed = 0` into it would silently strip
// suppressed rows from playlists and the playback queue — turning a hide into an
// effective delete at exactly the call sites the retain-don't-delete rule exists to
// protect. The exclusion is therefore applied ONE SITE AT A TIME, from this list:
//
// ## Sites that DO exclude (`cueSuppressed = 0`)
//   * `TrackRepository+Browse.fetchTracksPage`          — the library track list
//   * `TrackRepository+Browse.fetchTracksByRoot`        — a folder's track list
//   * `TrackRepository+Browse.fetchTracksByGenre`       — a genre's track list
//   * `TrackRepository+Browse.tracksByAlbum`            — an album's track list
//   * `TrackRepository+Browse.tracksByArtist`           — an artist's track list
//   * `TrackRepository+Browse.recentlyAddedObservation` — the recently-added list
//   * `TrackRepository+Facets.searchTracks`             — FTS5 result mapping
//
// ## Sites that MUST NOT exclude
//   * playlist-member reads (`PlaylistRepository`) — a suppressed row the user
//     already playlisted must still resolve, or the entry becomes a dangling id.
//   * queue / playback resolution (`TrackRepository.fetchTrack`, `tracksByPaths`) —
//     the same row must stay playable from wherever it is referenced.
//   * `AvailabilityReconciler` — a suppressed row's file can still go missing, and
//     skipping it would freeze its availability at a stale value forever.
//   * stats / play-event readers (`PlayEventRepository`, `PlaySegmentHeatRepository`,
//     `TrackRepository.resolvedTracks`) — listening history is retained BECAUSE the
//     row is retained; filtering here would discard the history it protects.
import GRDB

/// The `track.cueSuppressed` browse/search exclusion. See the file header for the
/// exhaustive list of sites allowed to apply it.
public enum CueSuppression {
    /// The GRDB predicate selecting rows no `.cue` sheet has superseded.
    public static var notSuppressed: SQLExpression {
        TrackRecord.Columns.cueSuppressed == false
    }

    /// The raw-SQL spelling of ``notSuppressed``, for the statements built as text.
    /// `qualifier` is a trusted table alias (`"track"`), never user input.
    public static func notSuppressedSQL(qualifier: String? = nil) -> String {
        let prefix = qualifier.map { "\($0)." } ?? ""
        return "\(prefix)cueSuppressed = 0"
    }
}
