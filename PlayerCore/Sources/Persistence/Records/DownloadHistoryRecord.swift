import Foundation
import GRDB

/// One completed or failed download attempt.
///
/// Maps the `downloadHistory` table. Every field is **denormalised on purpose**: the
/// title, uploader, duration, format and destination are snapshotted at capture so
/// the entry survives moving the file, deleting it, or never importing it into the
/// library at all. For the same reason the table declares **no foreign keys** — not
/// to `track`, not to `profile` — which is the `playEvent` survivability precedent
/// applied to downloads.
///
/// ``id`` is a caller-minted UUID string, so this conforms to `PersistableRecord`
/// (not `MutablePersistableRecord`): there is nothing to write back after insert,
/// exactly like ``TrackAudioFeatureRecord`` and ``ProfilePlaybackStateRecord``.
public struct DownloadHistoryRecord: Codable, Sendable, Equatable, Hashable {
    /// Caller-minted UUID string; the table's whole primary key.
    public var id: String
    /// The canonical YouTube video id this download came from. Indexed, and the key
    /// both ``DownloadHistoryRepositoryProviding/latestEntry(canonicalVideoID:)`` and
    /// ``DownloadHistoryRepositoryProviding/knownVideoIDs(in:)`` look up.
    public var canonicalVideoID: String
    /// Title as known when the download finished.
    public var title: String?
    /// Uploader/channel as known when the download finished.
    public var uploader: String?
    /// Track length in seconds, or `nil` when the engine never reported one.
    public var durationSeconds: Double?
    /// Absolute output path. Empty for failures to preserve the v17 non-null column.
    public var filePath: String
    /// The recorded failure explanation. Nil for successful downloads, including
    /// rows created before v21.
    public var failureReason: String?
    /// Raw value of the `DownloadAudioFormat` the file was written as.
    public var audioFormat: String
    /// Raw value of the `DownloadAudioQuality` the download was requested at.
    public var audioQuality: String
    /// The URL the download was queued from.
    public var sourceURL: String
    /// When the download finished, as seconds since the Unix epoch.
    public var downloadedAt: TimeInterval
    /// Seconds east of GMT at capture. Lets a row be rendered at the wall-clock time
    /// it was actually downloaded without consulting a `Calendar` at read time.
    public var utcOffsetSeconds: Int

    public init(
        id: String,
        canonicalVideoID: String,
        title: String? = nil,
        uploader: String? = nil,
        durationSeconds: Double? = nil,
        filePath: String,
        audioFormat: String,
        audioQuality: String,
        sourceURL: String,
        downloadedAt: TimeInterval,
        utcOffsetSeconds: Int,
        failureReason: String? = nil
    ) {
        self.id = id
        self.canonicalVideoID = canonicalVideoID
        self.title = title
        self.uploader = uploader
        self.durationSeconds = durationSeconds
        self.filePath = filePath
        self.failureReason = failureReason
        self.audioFormat = audioFormat
        self.audioQuality = audioQuality
        self.sourceURL = sourceURL
        self.downloadedAt = downloadedAt
        self.utcOffsetSeconds = utcOffsetSeconds
    }
}

extension DownloadHistoryRecord: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "downloadHistory"

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let canonicalVideoID = Column(CodingKeys.canonicalVideoID)
        public static let title = Column(CodingKeys.title)
        public static let uploader = Column(CodingKeys.uploader)
        public static let durationSeconds = Column(CodingKeys.durationSeconds)
        public static let filePath = Column(CodingKeys.filePath)
        public static let failureReason = Column(CodingKeys.failureReason)
        public static let audioFormat = Column(CodingKeys.audioFormat)
        public static let audioQuality = Column(CodingKeys.audioQuality)
        public static let sourceURL = Column(CodingKeys.sourceURL)
        public static let downloadedAt = Column(CodingKeys.downloadedAt)
        public static let utcOffsetSeconds = Column(CodingKeys.utcOffsetSeconds)
    }
}
