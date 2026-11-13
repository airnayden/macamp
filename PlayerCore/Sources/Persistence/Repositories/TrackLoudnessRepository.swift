import Foundation
import GRDB

/// Off-actor access to the v18 `trackLoudness` analysis cache.
///
/// Every read is either a primary-key seek, a bounded batch, or a keyset window —
/// never a full-table load, so a 100k library costs the same as a small one. The
/// scanner that fills this table (todo 10) keeps **no marker table**: a track stops
/// being a stale candidate the instant its row lands, so an interrupted pass resumes
/// by asking ``staleCandidates(analysisVersion:after:limit:)`` the same question
/// again. That is the ``TrackAudioFeatureRecord`` arrangement, reproduced here.
public protocol TrackLoudnessRepositoryProviding: Sendable {
    /// One track's cached loudness, or `nil` when it has never been analysed.
    func loudness(forTrackId trackId: Int64) async throws -> TrackLoudnessRecord?

    /// Cached loudness for up to ``TrackLoudnessRepository/fetchLimit`` tracks.
    ///
    /// The batch read album pooling uses: a page-50 batch routinely splits an album,
    /// and a member outside the current page must be pooled from its stored histogram
    /// rather than re-decoded. Rows are returned in `trackId` order; ids with no row
    /// are simply absent, which is what "this group is not complete yet" looks like.
    func loudness(forTrackIds trackIds: [Int64]) async throws -> [TrackLoudnessRecord]

    /// Inserts or replaces the row for `record.trackId`.
    func upsert(_ record: TrackLoudnessRecord) async throws

    /// How many present tracks still need analysis at `analysisVersion`.
    func staleCandidateCount(analysisVersion: Int) async throws -> Int

    /// One keyset page of present tracks needing analysis, ordered by `track.id`.
    func staleCandidates(
        analysisVersion: Int,
        after cursor: PageCursor<Int64>?,
        limit: Int
    ) async throws -> Page<TrackRecord, Int64>

    /// Writes one pooled album result onto every member, in one transaction.
    ///
    /// Applied to **all** members including previously-completed ones, so a group can
    /// never hold two different album figures. A member with no `trackLoudness` row is
    /// silently unaffected — the group was not complete, and the caller is expected to
    /// have established completeness before pooling.
    func applyAlbumLoudness(trackIds: [Int64], albumLUFS: Double, albumPeak: Double) async throws

    /// Empties the table, so the next pass re-analyses the whole library.
    func deleteAll() async throws
}

/// The concrete ``TrackLoudnessRepositoryProviding`` over a GRDB writer.
public struct TrackLoudnessRepository: TrackLoudnessRepositoryProviding {
    /// The hard ceiling on any single page or batch, applied even when a caller asks
    /// for more.
    public static let fetchLimit = 500

    /// Internal, NOT `private`: the ``TrackLoudnessInvalidating`` conformance lives
    /// in a sibling file beside its own protocol, and `private` is file-scoped.
    let dbWriter: any DatabaseWriter

    public init(_ appDatabase: AppDatabase) {
        dbWriter = appDatabase.writer
    }

    public init(_ dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    public func loudness(forTrackId trackId: Int64) async throws -> TrackLoudnessRecord? {
        try await dbWriter.read { db in
            try TrackLoudnessRecord.fetchOne(db, key: trackId)
        }
    }

    public func loudness(forTrackIds trackIds: [Int64]) async throws -> [TrackLoudnessRecord] {
        let capped = Array(trackIds.prefix(Self.fetchLimit))
        guard !capped.isEmpty else { return [] }
        return try await dbWriter.read { db in
            try TrackLoudnessRecord
                .filter(capped.contains(TrackLoudnessRecord.Columns.trackId))
                .order(TrackLoudnessRecord.Columns.trackId)
                .fetchAll(db)
        }
    }

    public func upsert(_ record: TrackLoudnessRecord) async throws {
        try await dbWriter.write { db in
            try record.upsert(db)
        }
    }

    public func staleCandidateCount(analysisVersion: Int) async throws -> Int {
        try await dbWriter.read { db in
            try Int.fetchOne(
                db,
                sql: Self.staleCountSQL,
                arguments: [Availability.present.rawValue, analysisVersion]
            ) ?? 0
        }
    }

    public func staleCandidates(
        analysisVersion: Int,
        after cursor: PageCursor<Int64>? = nil,
        limit: Int = TrackLoudnessRepository.fetchLimit
    ) async throws -> Page<TrackRecord, Int64> {
        let capped = min(max(1, limit), Self.fetchLimit)
        let anchor = cursor?.id ?? 0
        return try await dbWriter.read { db in
            let overFetched = try TrackRecord.fetchAll(
                db,
                sql: Self.stalePageSQL,
                arguments: [Availability.present.rawValue, anchor, analysisVersion, capped + 1]
            )
            return makePage(from: overFetched, limit: capped) { track in
                PageCursor(key: track.id ?? 0, id: track.id ?? 0)
            }
        }
    }

    public func applyAlbumLoudness(
        trackIds: [Int64],
        albumLUFS: Double,
        albumPeak: Double
    ) async throws {
        let capped = Array(trackIds.prefix(Self.fetchLimit))
        guard !capped.isEmpty else { return }
        try await dbWriter.write { db in
            try TrackLoudnessRecord
                .filter(capped.contains(TrackLoudnessRecord.Columns.trackId))
                .updateAll(
                    db,
                    TrackLoudnessRecord.Columns.albumLUFS.set(to: albumLUFS),
                    TrackLoudnessRecord.Columns.albumPeak.set(to: albumPeak)
                )
        }
    }

    /// Unbounded by design and safe to be: a `DELETE` with no `WHERE` is answered by
    /// SQLite's truncate optimisation, which drops pages rather than materialising
    /// rows, so a 100k library costs no more memory than an empty one.
    public func deleteAll() async throws {
        try await dbWriter.write { db in
            try db.execute(sql: "DELETE FROM trackLoudness")
        }
    }
}

// MARK: - Staleness (SQL)

private extension TrackLoudnessRepository {
    /// A track is a candidate while NO `trackLoudness` row matches both the requested
    /// `analysisVersion` and the file's fingerprint. One clause covers all three
    /// reasons to analyse: never analysed, the file changed since, and analysed by an
    /// older analyser.
    ///
    /// `COALESCE(…, 0)` is what makes a track with no recorded fingerprint TERMINATE.
    /// `track.fileSize`/`track.mtime` are nullable, and a bare comparison against NULL
    /// is never true, so such a track would look stale on every future pass and be
    /// re-analysed forever. The writer stamps the same `0` sentinel, so instead it is
    /// analysed exactly once — and re-analysed the moment a re-scan gives it a real
    /// fingerprint. This is ``TrackAudioFeatureRecord``'s clause verbatim.
    ///
    /// The two cue terms compare the stored bounds against the **`track` columns**
    /// v20 added — they were pinned to the whole-file `-1`/`NULL` sentinel only while
    /// those columns did not exist. A cue segment is therefore fresh when its row was
    /// measured over ITS OWN bounds, and a whole-file row measured before a `.cue`
    /// sidecar carved the file into segments no longer satisfies any of them.
    ///
    /// `cueEndFrame` is compared with `IS`, not `=`: it is nullable on BOTH sides and
    /// `NULL = NULL` is never true, so `=` would make every open-ended segment (and
    /// every whole file) look stale on every pass — re-analysed forever, which is the
    /// exact failure `COALESCE(…, 0)` exists to prevent two lines above.
    static var staleFingerprintClause: String {
        """
        NOT EXISTS (
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

    /// One bounded page of stale tracks. `track.id` is a rowid alias starting at 1, so
    /// a `0` anchor selects the whole table and the cursor needs no conditional SQL.
    ///
    /// Argument order is the `?` order in the final string:
    /// availability, cursor, analysis version, limit.
    static var stalePageSQL: String {
        """
        SELECT track.* FROM track
        WHERE track.availability = ? AND track.id > ? AND \(staleFingerprintClause)
        ORDER BY track.id ASC
        LIMIT ?
        """
    }

    /// The pass total, counted once at start. Arguments: availability, version.
    static var staleCountSQL: String {
        """
        SELECT COUNT(*) FROM track
        WHERE track.availability = ? AND \(staleFingerprintClause)
        """
    }
}
