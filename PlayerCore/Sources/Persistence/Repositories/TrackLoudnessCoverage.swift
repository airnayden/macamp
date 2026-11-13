// TrackLoudnessCoverage — how much of the library carries usable loudness analysis.
//
// ``AudioFeatureCoverage``'s twin, read against `trackLoudness` instead of
// `trackAudioFeature`. It exists for the same reason that one does: the Playback
// pane's "34% analyzed" line is a LIBRARY-WIDE fact and must never be derived
// from ``LoudnessScanning/progress``, whose `total` is a snapshot of the STALE
// set taken once at pass start — so a fully analysed library reports `(0, 0)` and
// a library scan landing mid-pass can push `completed` past `total`.
//
// The freshness clause below is the POSITIVE twin of
// `TrackLoudnessRepository.staleFingerprintClause`, so the two partition the same
// population and `analyzed + stale == total` by construction. That identity is
// what lets the coverage read-out and
// ``TrackLoudnessRepositoryProviding/staleCandidateCount(analysisVersion:)``
// agree without either querying the other.
//
// Both counts are `COUNT(*)`-shaped conditional aggregates over indexed columns
// with no row materialised, so this stays bounded on a 100k library.
import Foundation
import GRDB

/// How much of a track population carries cached BS.1770-4 loudness.
///
/// Two readings, for the same reason ``AudioFeatureCoverage`` carries two:
///
///  * ``analyzed`` (version- and fingerprint-checked) answers "how much is still
///    to do" — the reading that agrees with the scan pass.
///  * ``measured`` (a row exists at all) answers "how much can playback fall back
///    on", which is what ``ReplayGainSource/computed`` is served from: the
///    resolver compares the row's own cue bounds, not its fingerprint, so a
///    fingerprint-stale row still normalises a track.
public struct TrackLoudnessCoverage: Sendable, Equatable, Hashable {
    /// Tracks carrying a `trackLoudness` row that matches the current analysis
    /// version, the file's `(fileSize, mtime)` fingerprint and the whole-file cue
    /// sentinel.
    public let analyzed: Int

    /// Tracks carrying **any** `trackLoudness` row, fresh or stale.
    public let measured: Int

    /// Tracks in the population.
    public let total: Int

    /// Clamps into `0 <= analyzed <= measured <= total`, so no caller can build a
    /// fraction above 1.
    public init(analyzed: Int, measured: Int, total: Int) {
        let boundedTotal = max(0, total)
        let boundedMeasured = min(max(0, measured), boundedTotal)
        self.total = boundedTotal
        self.measured = boundedMeasured
        self.analyzed = min(max(0, analyzed), boundedMeasured)
    }

    /// `analyzed / total`, in `0...1`; zero for an empty population.
    public var fraction: Double {
        guard total > 0 else { return 0 }
        return Double(analyzed) / Double(total)
    }

    /// Present tracks the next pass would still measure — the figure that must
    /// equal `staleCandidateCount(analysisVersion:)` for the same version.
    public var stale: Int {
        total - analyzed
    }
}

/// Bounded coverage queries over `trackLoudness`.
public enum TrackLoudnessCoverageReader {
    /// Coverage over **every** `present` track, unscoped by profile.
    ///
    /// Profile-unscoped on purpose, exactly as
    /// ``AudioFeatureCoverageReader/libraryCoverage(_:analysisVersion:)`` is:
    /// loudness describes the FILE, `trackLoudness` carries no `profileId`, and
    /// ``LoudnessScanning`` walks precisely this population. A scoped denominator
    /// would make the read-out disagree with the pass that fills it.
    ///
    /// - Parameter analysisVersion: The analyser version a row must carry to
    ///   count as analysed — pass `LoudnessScanService.analysisVersion`. It
    ///   travels as an argument because `Persistence` sits *below* `Services` and
    ///   cannot import that constant.
    public static func libraryCoverage(_ db: Database, analysisVersion: Int) throws -> TrackLoudnessCoverage {
        let row = try Row.fetchOne(db, sql: """
        SELECT
          SUM(CASE WHEN \(freshLoudnessClause) THEN 1 ELSE 0 END) AS analyzed,
          SUM(CASE WHEN \(anyLoudnessClause) THEN 1 ELSE 0 END) AS measured,
          COUNT(*) AS total
        FROM track
        WHERE track.availability = ?
        """, arguments: [analysisVersion, Availability.present.rawValue])
        guard let row else { return TrackLoudnessCoverage(analyzed: 0, measured: 0, total: 0) }
        let analyzed: Int = row["analyzed"] ?? 0
        let measured: Int = row["measured"] ?? 0
        let total: Int = row["total"] ?? 0
        return TrackLoudnessCoverage(analyzed: analyzed, measured: measured, total: total)
    }
}

// MARK: - Counting

private extension TrackLoudnessCoverageReader {
    /// The freshness test, as the positive twin of
    /// `TrackLoudnessRepository.staleFingerprintClause`.
    ///
    /// The repository asks `NOT EXISTS(…)` ("still to do"); this asks `EXISTS(…)`
    /// ("already done"). **They must stay in sync** — including the two cue terms,
    /// which compare against the `track.cueStartFrame`/`cueEndFrame` columns v20
    /// added (they were pinned to the whole-file sentinel only while those columns
    /// did not exist). Restated rather than shared because the repository keeps its
    /// clause `private` and both live in this module for the same reason
    /// `AudioFeatureCoverageReader` restates the pass's.
    ///
    /// `COALESCE(…, 0)` mirrors the repository for the reason it exists there:
    /// `track.fileSize`/`track.mtime` are nullable and a bare comparison against
    /// `NULL` is never true, so a nil-fingerprint track would never count as
    /// analysed however often it was analysed. `cueEndFrame` is compared with `IS`
    /// for the same reason: it is nullable on both sides.
    static var freshLoudnessClause: String {
        """
        EXISTS (
          SELECT 1 FROM trackLoudness
          WHERE trackLoudness.trackId = track.id
            AND trackLoudness.analysisVersion = ?
            AND trackLoudness.fileSize = COALESCE(track.fileSize, 0)
            AND trackLoudness.mtime = COALESCE(track.mtime, 0)
            AND trackLoudness.cueStartFrame = track.cueStartFrame
            AND trackLoudness.cueEndFrame IS track.cueEndFrame
        )
        """
    }

    /// What the playback fallback can see: a row for the track, whatever version
    /// or fingerprint it carries.
    static var anyLoudnessClause: String {
        "EXISTS (SELECT 1 FROM trackLoudness WHERE trackLoudness.trackId = track.id)"
    }
}
