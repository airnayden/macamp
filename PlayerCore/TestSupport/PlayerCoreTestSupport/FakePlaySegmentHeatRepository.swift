// FakePlaySegmentHeatRepository — an in-memory ``PlaySegmentHeatRepositoryProviding``.
//
// No GRDB, no file system: rows live in a dictionary keyed by (profile, track), so a
// consumer's gating, normalization and rescoping can be asserted without a database.
// It is a `struct` over a lock box rather than an `actor` on purpose — an actor's
// methods hop to the actor's own executor, which would make "the read ran off the
// main thread" true by construction and therefore worthless as an assertion. Here
// each requirement's body runs on whatever executor the caller's `await` resolved
// to, so ``Recording/mainThreadReads`` is a REAL measurement of whether a caller
// blocked the UI.
//
// Semantics mirror the production ``PlaySegmentHeatRepository``: merges saturate at
// `UInt32.max`, an all-zero merge writes nothing at all, a stored identity field is
// never blanked by a `nil` incoming one, and `allSegmentHeat` keysets on
// `(trackId, id)` ascending.
import Darwin
import Foundation
import GRDB
import os
import Persistence

/// Thrown by ``FakePlaySegmentHeatRepository`` when a test arms a read failure.
public enum FakeSegmentHeatError: Error, Sendable, Equatable {
    case forcedReadFailure
}

/// An in-memory replay-heatmap store for hermetic tests and previews.
public struct FakePlaySegmentHeatRepository: PlaySegmentHeatRepositoryProviding {
    /// The hard page ceiling, matching the production repository.
    public static let fetchLimit = 500

    /// Identifies one heatmap row.
    public struct Key: Hashable, Sendable {
        public var profileId: Int64
        public var trackId: Int64

        public init(profileId: Int64, trackId: Int64) {
            self.profileId = profileId
            self.trackId = trackId
        }
    }

    /// Everything the fake stores and observes, guarded as one unit.
    public struct Recording: Sendable {
        public var rows: [Key: PlaySegmentHeatRecord] = [:]
        /// Keys handed to ``segmentHeat(profileId:trackId:)``, in call order.
        public var reads: [Key] = []
        /// Keys handed to `mergeSegmentHeat`, in call order.
        public var merges: [Key] = []
        /// How many reads were serviced while still on the main thread.
        public var mainThreadReads = 0
        /// When `true`, every read throws ``FakeSegmentHeatError/forcedReadFailure``.
        public var readShouldFail = false
    }

    private let state: OSAllocatedUnfairLock<Recording>

    public init(rows: [Key: PlaySegmentHeatRecord] = [:]) {
        var recording = Recording()
        recording.rows = rows
        state = OSAllocatedUnfairLock(initialState: recording)
    }

    /// A snapshot of everything recorded so far.
    public var recording: Recording {
        state.withLock { $0 }
    }

    public func seed(_ record: PlaySegmentHeatRecord) {
        let key = Key(profileId: record.profileId, trackId: record.trackId)
        state.withLock { $0.rows[key] = record }
    }

    public func setReadShouldFail(_ shouldFail: Bool) {
        state.withLock { $0.readShouldFail = shouldFail }
    }

    public func segmentHeat(profileId: Int64, trackId: Int64) async throws -> PlaySegmentHeatRecord? {
        // `Thread.isMainThread` is unavailable from an async context; `pthread_main_np`
        // is the same question asked in a form the concurrency checker allows.
        let onMain = pthread_main_np() != 0
        let key = Key(profileId: profileId, trackId: trackId)
        return try state.withLock { recording in
            recording.reads.append(key)
            if onMain { recording.mainThreadReads += 1 }
            guard !recording.readShouldFail else { throw FakeSegmentHeatError.forcedReadFailure }
            return recording.rows[key]
        }
    }

    public func mergeSegmentHeat(
        profileId: Int64,
        trackId: Int64,
        identity: PlaySegmentIdentity,
        deltas: [UInt32],
        updatedAt: TimeInterval
    ) async throws {
        guard deltas.count == PlaySegmentHeatRecord.bucketCount else {
            throw PlaySegmentHeatError.invalidBucketCountsSize(
                expected: PlaySegmentHeatRecord.bucketCountsByteCount,
                actual: deltas.count * MemoryLayout<UInt32>.size
            )
        }
        guard deltas.contains(where: { $0 > 0 }) else { return }
        let key = Key(profileId: profileId, trackId: trackId)
        try state.withLock { recording in
            recording.merges.append(key)
            recording.rows[key] = try Self.merged(
                recording.rows[key],
                key: key,
                identity: identity,
                deltas: deltas,
                updatedAt: updatedAt
            )
        }
    }

    public func allSegmentHeat(
        profileId: Int64,
        after cursor: PageCursor<Int64>?,
        limit: Int
    ) async throws -> Page<PlaySegmentHeatRecord, Int64> {
        let capped = min(max(1, limit), Self.fetchLimit)
        let ordered = state.withLock { $0.rows }
            .values
            .filter { $0.profileId == profileId }
            .sorted(by: Self.isOrderedBefore)
        let remaining = cursor.map { anchor in ordered.filter { Self.isAfter($0, anchor) } } ?? ordered
        let items = Array(remaining.prefix(capped))
        guard remaining.count > capped, let last = items.last else {
            return Page(items: items, nextCursor: nil)
        }
        return Page(items: items, nextCursor: PageCursor(key: last.trackId, id: last.id ?? 0))
    }
}

// MARK: - Row construction

public extension FakePlaySegmentHeatRepository {
    /// Builds a row directly from bucket counts, so a test states the shape it wants
    /// instead of encoding a 400-byte blob by hand.
    static func record(
        profileId: Int64,
        trackId: Int64,
        buckets: [UInt32],
        totalPasses: Int,
        durationSeconds: Double = 200
    ) throws -> PlaySegmentHeatRecord {
        try PlaySegmentHeatRecord(
            id: trackId,
            profileId: profileId,
            trackId: trackId,
            durationSeconds: durationSeconds,
            bucketCounts: PlaySegmentHeatRecord.encodeBuckets(buckets),
            totalPasses: totalPasses,
            updatedAt: 0
        )
    }
}

// MARK: - Ordering + merge maths

private extension FakePlaySegmentHeatRepository {
    static func isOrderedBefore(_ lhs: PlaySegmentHeatRecord, _ rhs: PlaySegmentHeatRecord) -> Bool {
        lhs.trackId == rhs.trackId ? (lhs.id ?? 0) < (rhs.id ?? 0) : lhs.trackId < rhs.trackId
    }

    static func isAfter(_ row: PlaySegmentHeatRecord, _ anchor: PageCursor<Int64>) -> Bool {
        row.trackId == anchor.key ? (row.id ?? 0) > anchor.id : row.trackId > anchor.key
    }

    static func merged(
        _ existing: PlaySegmentHeatRecord?,
        key: Key,
        identity: PlaySegmentIdentity,
        deltas: [UInt32],
        updatedAt: TimeInterval
    ) throws -> PlaySegmentHeatRecord {
        guard var merged = existing else {
            return try PlaySegmentHeatRecord(
                id: key.trackId,
                profileId: key.profileId,
                trackId: key.trackId,
                artistName: identity.artistName,
                title: identity.title,
                albumTitle: identity.albumTitle,
                genre: identity.genre,
                durationSeconds: identity.durationSeconds,
                bucketCounts: PlaySegmentHeatRecord.encodeBuckets(deltas),
                totalPasses: 1,
                updatedAt: updatedAt
            )
        }
        let stored = try merged.decodedBuckets()
        merged.bucketCounts = try PlaySegmentHeatRecord.encodeBuckets(Self.saturatingSum(stored, deltas))
        merged.totalPasses += 1
        merged.updatedAt = updatedAt
        merged.durationSeconds = identity.durationSeconds
        merged.artistName = identity.artistName ?? merged.artistName
        merged.title = identity.title ?? merged.title
        merged.albumTitle = identity.albumTitle ?? merged.albumTitle
        merged.genre = identity.genre ?? merged.genre
        return merged
    }

    /// Clamps at `UInt32.max` instead of wrapping — a saturated bucket reads as
    /// "played a great many times", a wrapped one as "never played".
    static func saturatingSum(_ counts: [UInt32], _ deltas: [UInt32]) -> [UInt32] {
        zip(counts, deltas).map { count, delta in
            let sum = UInt64(count) + UInt64(delta)
            return sum > UInt64(UInt32.max) ? UInt32.max : UInt32(sum)
        }
    }
}
