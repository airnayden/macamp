import Foundation
import GRDB

/// Why a ``PlaySegmentHeatRecord`` was refused.
public enum PlaySegmentHeatError: Error, Sendable, Equatable {
    /// The `bucketCounts` blob was not exactly
    /// ``PlaySegmentHeatRecord/bucketCountsByteCount`` bytes. Rejected rather than
    /// padded or truncated: a short blob would silently misalign every bucket.
    case invalidBucketCountsSize(expected: Int, actual: Int)
}

/// A per-track replay heatmap: which *parts* of a song a profile replays.
///
/// Maps the `playSegmentHeat` table, one row per `(profileId, trackId)`. Like
/// `playEvent`, ``trackId`` is a bare `Int64` with **no foreign key** and the metadata
/// is snapshotted at capture, so the heatmap survives deleting the track. Only
/// ``profileId`` cascades.
///
/// ``bucketCounts`` is a fixed 400-byte blob: ``bucketCount`` little-endian `UInt32`
/// listen counts where bucket `i` covers `[i%, (i+1)%)` of ``durationSeconds``.
/// Relative buckets keep the row one fixed width whatever the track's length, and the
/// explicit little-endian encoding keeps it portable across machines when a profile is
/// exported. Any other length is rejected on save via ``validate()``.
public struct PlaySegmentHeatRecord: Codable, Sendable, Equatable, Hashable {
    /// Number of relative buckets a track is divided into.
    public static let bucketCount = 100
    /// The exact byte length of a valid ``bucketCounts`` blob.
    public static let bucketCountsByteCount = bucketCount * MemoryLayout<UInt32>.size

    /// Auto-incremented rowid primary key. `nil` until the record is inserted.
    public var id: Int64?
    /// Owning profile (`ON DELETE CASCADE`).
    public var profileId: Int64
    /// The library track this heatmap describes. Not a foreign key: the referenced row
    /// may be long gone.
    public var trackId: Int64
    /// Artist as known at capture time.
    public var artistName: String?
    /// Title as known at capture time.
    public var title: String?
    /// Album as known at capture time.
    public var albumTitle: String?
    /// Genre as known at capture time.
    public var genre: String?
    /// Track length the buckets were computed against.
    public var durationSeconds: Double
    /// ``bucketCount`` little-endian `UInt32` counts, exactly
    /// ``bucketCountsByteCount`` bytes.
    public var bucketCounts: Data
    /// Committed flush passes folded into this row.
    public var totalPasses: Int
    /// Last write time, as seconds since the Unix epoch.
    public var updatedAt: TimeInterval

    public init(
        id: Int64? = nil,
        profileId: Int64,
        trackId: Int64,
        artistName: String? = nil,
        title: String? = nil,
        albumTitle: String? = nil,
        genre: String? = nil,
        durationSeconds: Double,
        bucketCounts: Data,
        totalPasses: Int = 0,
        updatedAt: TimeInterval
    ) {
        self.id = id
        self.profileId = profileId
        self.trackId = trackId
        self.artistName = artistName
        self.title = title
        self.albumTitle = albumTitle
        self.genre = genre
        self.durationSeconds = durationSeconds
        self.bucketCounts = bucketCounts
        self.totalPasses = totalPasses
        self.updatedAt = updatedAt
    }
}

// MARK: - Bucket encoding

public extension PlaySegmentHeatRecord {
    /// An all-zero blob of the correct length, for a track with no history yet.
    static var emptyBucketCounts: Data {
        Data(count: bucketCountsByteCount)
    }

    /// Packs ``bucketCount`` counts into a little-endian blob.
    static func encodeBuckets(_ buckets: [UInt32]) throws -> Data {
        guard buckets.count == bucketCount else {
            throw PlaySegmentHeatError.invalidBucketCountsSize(
                expected: bucketCountsByteCount,
                actual: buckets.count * MemoryLayout<UInt32>.size
            )
        }
        var data = Data(capacity: bucketCountsByteCount)
        for bucket in buckets {
            withUnsafeBytes(of: bucket.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Unpacks a little-endian blob back into ``bucketCount`` counts.
    ///
    /// The bytes are reassembled by explicit shifting rather than a raw load, so the
    /// stored format stays little-endian regardless of the host's byte order.
    static func decodeBuckets(_ data: Data) throws -> [UInt32] {
        try validateBucketCounts(data)
        let width = MemoryLayout<UInt32>.size
        return (0 ..< bucketCount).map { index in
            let start = data.startIndex + index * width
            var value: UInt32 = 0
            for offset in 0 ..< width {
                value |= UInt32(data[start + offset]) << (8 * offset)
            }
            return value
        }
    }

    /// Throws unless `data` is exactly ``bucketCountsByteCount`` bytes.
    static func validateBucketCounts(_ data: Data) throws {
        guard data.count == bucketCountsByteCount else {
            throw PlaySegmentHeatError.invalidBucketCountsSize(
                expected: bucketCountsByteCount,
                actual: data.count
            )
        }
    }

    /// This row's counts.
    func decodedBuckets() throws -> [UInt32] {
        try Self.decodeBuckets(bucketCounts)
    }

    /// Throws ``PlaySegmentHeatError/invalidBucketCountsSize(expected:actual:)`` unless
    /// ``bucketCounts`` is well-formed.
    func validate() throws {
        try Self.validateBucketCounts(bucketCounts)
    }
}

extension PlaySegmentHeatRecord: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "playSegmentHeat"

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let profileId = Column(CodingKeys.profileId)
        public static let trackId = Column(CodingKeys.trackId)
        public static let artistName = Column(CodingKeys.artistName)
        public static let title = Column(CodingKeys.title)
        public static let albumTitle = Column(CodingKeys.albumTitle)
        public static let genre = Column(CodingKeys.genre)
        public static let durationSeconds = Column(CodingKeys.durationSeconds)
        public static let bucketCounts = Column(CodingKeys.bucketCounts)
        public static let totalPasses = Column(CodingKeys.totalPasses)
        public static let updatedAt = Column(CodingKeys.updatedAt)
    }

    /// GRDB calls this before every insert and update, so a malformed blob can never
    /// reach the database — whichever write path a caller takes.
    public func willSave(_: Database) throws {
        try validate()
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
