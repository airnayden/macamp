import Foundation
import GRDB

/// The metadata a heatmap row snapshots at capture time.
///
/// Kept beside the counts rather than joined from `track`, because the whole point
/// of the heatmap is to outlive the track row: a folder the user removed, a file
/// they deleted, a library they re-scanned. Every field is optional except the
/// duration the buckets were computed against, which the caller must know for the
/// bucket maths to mean anything.
public struct PlaySegmentIdentity: Sendable, Equatable, Hashable {
    public var artistName: String?
    public var title: String?
    public var albumTitle: String?
    public var genre: String?
    /// Track length the relative buckets are measured against. Must be `> 0`.
    public var durationSeconds: Double

    public init(
        artistName: String? = nil,
        title: String? = nil,
        albumTitle: String? = nil,
        genre: String? = nil,
        durationSeconds: Double
    ) {
        self.artistName = artistName
        self.title = title
        self.albumTitle = albumTitle
        self.genre = genre
        self.durationSeconds = durationSeconds
    }
}

/// Off-actor access to the v15 `playSegmentHeat` replay heatmaps.
///
/// One row per `(profileId, trackId)`. Writes are additive merges rather than
/// replacements, so a caller only ever has to compute the deltas for the listen it
/// just observed; reads are single-row or keyset-windowed, never a full table load.
public protocol PlaySegmentHeatRepositoryProviding: Sendable {
    /// This profile's heatmap for one track, or `nil` when it has never been played.
    func segmentHeat(profileId: Int64, trackId: Int64) async throws -> PlaySegmentHeatRecord?

    /// Folds `deltas` into the profile's heatmap for `trackId`, in ONE transaction.
    ///
    /// Existing counts and `deltas` are summed per bucket, **saturating** at
    /// `UInt32.max` rather than wrapping. The row is created on first write carrying
    /// `identity`; on later writes each identity field is refreshed only when the
    /// incoming value is non-`nil`, so a merge that happens after the track row was
    /// deleted can never blank a good snapshot. `totalPasses` is bumped by one — and
    /// the whole call is a no-op — exactly when at least one delta is non-zero.
    ///
    /// - Throws: ``PlaySegmentHeatError/invalidBucketCountsSize(expected:actual:)``
    ///   when `deltas` is not ``PlaySegmentHeatRecord/bucketCount`` long.
    func mergeSegmentHeat(
        profileId: Int64,
        trackId: Int64,
        identity: PlaySegmentIdentity,
        deltas: [UInt32],
        updatedAt: TimeInterval
    ) async throws

    /// One keyset page of a profile's heatmaps, ordered by `(trackId, id)`.
    ///
    /// The digest (todo 5) and the archive (todo 6) read every row through this
    /// window, so the order is total and the page size is capped.
    func allSegmentHeat(
        profileId: Int64,
        after cursor: PageCursor<Int64>?,
        limit: Int
    ) async throws -> Page<PlaySegmentHeatRecord, Int64>
}

/// The concrete ``PlaySegmentHeatRepositoryProviding`` over a GRDB writer.
public struct PlaySegmentHeatRepository: PlaySegmentHeatRepositoryProviding {
    /// The hard ceiling on any single page, applied even when a caller asks for more.
    public static let fetchLimit = 500

    private let dbWriter: any DatabaseWriter

    public init(_ appDatabase: AppDatabase) {
        dbWriter = appDatabase.writer
    }

    public init(_ dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    public func segmentHeat(profileId: Int64, trackId: Int64) async throws -> PlaySegmentHeatRecord? {
        try await dbWriter.read { db in
            try Self.existingRow(db, profileId: profileId, trackId: trackId)
        }
    }

    public func mergeSegmentHeat(
        profileId: Int64,
        trackId: Int64,
        identity: PlaySegmentIdentity,
        deltas: [UInt32],
        updatedAt: TimeInterval = Date().timeIntervalSince1970
    ) async throws {
        guard deltas.count == PlaySegmentHeatRecord.bucketCount else {
            throw PlaySegmentHeatError.invalidBucketCountsSize(
                expected: PlaySegmentHeatRecord.bucketCountsByteCount,
                actual: deltas.count * MemoryLayout<UInt32>.size
            )
        }
        // Nothing was listened to, so there is no pass to count and no row to create.
        guard deltas.contains(where: { $0 > 0 }) else { return }
        try await dbWriter.write { db in
            guard let existing = try Self.existingRow(db, profileId: profileId, trackId: trackId) else {
                var created = try PlaySegmentHeatRecord(
                    profileId: profileId,
                    trackId: trackId,
                    artistName: identity.artistName,
                    title: identity.title,
                    albumTitle: identity.albumTitle,
                    genre: identity.genre,
                    durationSeconds: identity.durationSeconds,
                    bucketCounts: PlaySegmentHeatRecord.encodeBuckets(deltas),
                    totalPasses: 1,
                    updatedAt: updatedAt
                )
                try created.insert(db)
                return
            }
            try Self.merging(existing, identity: identity, deltas: deltas, updatedAt: updatedAt).update(db)
        }
    }

    public func allSegmentHeat(
        profileId: Int64,
        after cursor: PageCursor<Int64>? = nil,
        limit: Int = PlaySegmentHeatRepository.fetchLimit
    ) async throws -> Page<PlaySegmentHeatRecord, Int64> {
        let capped = min(max(1, limit), Self.fetchLimit)
        return try await dbWriter.read { db in
            try PlaySegmentHeatRecord
                .filter(PlaySegmentHeatRecord.Columns.profileId == profileId)
                .fetchPage(
                    db,
                    sort: KeysetSort(keyExpressionSQL: "\"trackId\""),
                    after: cursor,
                    limit: capped,
                    cursorForLast: { PageCursor(key: $0.trackId, id: $0.id ?? 0) }
                )
        }
    }
}

// MARK: - Merge maths

private extension PlaySegmentHeatRepository {
    static func existingRow(
        _ db: Database,
        profileId: Int64,
        trackId: Int64
    ) throws -> PlaySegmentHeatRecord? {
        try PlaySegmentHeatRecord
            .filter(PlaySegmentHeatRecord.Columns.profileId == profileId)
            .filter(PlaySegmentHeatRecord.Columns.trackId == trackId)
            .fetchOne(db)
    }

    /// Adds `deltas` to `existing`'s counts and refreshes what the caller knows.
    ///
    /// A `nil` incoming identity field means "I could not resolve this now" — most
    /// often because the track row is already gone — so the stored snapshot wins.
    static func merging(
        _ existing: PlaySegmentHeatRecord,
        identity: PlaySegmentIdentity,
        deltas: [UInt32],
        updatedAt: TimeInterval
    ) throws -> PlaySegmentHeatRecord {
        var merged = existing
        let summed = try saturatingSum(existing.decodedBuckets(), deltas)
        merged.bucketCounts = try PlaySegmentHeatRecord.encodeBuckets(summed)
        merged.totalPasses += 1
        merged.updatedAt = updatedAt
        merged.durationSeconds = identity.durationSeconds
        merged.artistName = identity.artistName ?? existing.artistName
        merged.title = identity.title ?? existing.title
        merged.albumTitle = identity.albumTitle ?? existing.albumTitle
        merged.genre = identity.genre ?? existing.genre
        return merged
    }

    /// Per-bucket addition that clamps at `UInt32.max` instead of wrapping — a
    /// saturated bucket is merely "played a great many times", whereas a wrapped one
    /// would read as never played.
    static func saturatingSum(_ counts: [UInt32], _ deltas: [UInt32]) -> [UInt32] {
        zip(counts, deltas).map { count, delta in
            let sum = UInt64(count) + UInt64(delta)
            return sum > UInt64(UInt32.max) ? UInt32.max : UInt32(sum)
        }
    }
}
