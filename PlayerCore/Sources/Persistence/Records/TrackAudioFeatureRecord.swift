import GRDB

/// Cached audio analysis for one track — tempo, energy and spectral brightness.
///
/// Maps the `trackAudioFeature` table, whose primary key is the caller-supplied
/// `trackId` — there is **no** separate `id` column. Because that key is not an
/// auto-increment rowid, this conforms to `PersistableRecord` (not
/// `MutablePersistableRecord`): there is nothing to write back after insert, exactly
/// like ``ProfileTrackStateRecord`` and ``ProfilePlaybackStateRecord``.
///
/// ``fileSize`` and ``mtime`` fingerprint the bytes that were analysed. A caller must
/// treat a row whose fingerprint no longer matches the file on disk — or whose
/// ``analysisVersion`` predates the current extractor — as absent and recompute it.
public struct TrackAudioFeatureRecord: Codable, Sendable, Equatable, Hashable {
    /// Analysed track (`ON DELETE CASCADE`) and the table's whole primary key.
    public var trackId: Int64
    /// Size in bytes of the analysed file; half of the staleness fingerprint.
    public var fileSize: Int64
    /// Modification time of the analysed file; the other half of the fingerprint.
    public var mtime: Double
    /// Estimated tempo in beats per minute, or `nil` when no reliable beat was found.
    public var bpm: Double?
    /// Perceived intensity, normalised to `0...1`.
    public var energy: Double
    /// Spectral brightness (high-frequency weight), normalised to `0...1`.
    public var brightness: Double
    /// Extractor schema version that produced these values.
    public var analysisVersion: Int
    /// When the analysis ran, as seconds since the Unix epoch.
    public var computedAt: Double

    public init(
        trackId: Int64,
        fileSize: Int64,
        mtime: Double,
        bpm: Double? = nil,
        energy: Double,
        brightness: Double,
        analysisVersion: Int,
        computedAt: Double
    ) {
        self.trackId = trackId
        self.fileSize = fileSize
        self.mtime = mtime
        self.bpm = bpm
        self.energy = energy
        self.brightness = brightness
        self.analysisVersion = analysisVersion
        self.computedAt = computedAt
    }
}

extension TrackAudioFeatureRecord: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "trackAudioFeature"

    public enum Columns {
        public static let trackId = Column(CodingKeys.trackId)
        public static let fileSize = Column(CodingKeys.fileSize)
        public static let mtime = Column(CodingKeys.mtime)
        public static let bpm = Column(CodingKeys.bpm)
        public static let energy = Column(CodingKeys.energy)
        public static let brightness = Column(CodingKeys.brightness)
        public static let analysisVersion = Column(CodingKeys.analysisVersion)
        public static let computedAt = Column(CodingKeys.computedAt)
    }
}

// MARK: - Associations

public extension TrackAudioFeatureRecord {
    /// The analysed track (`trackAudioFeature.trackId → track.id`).
    static let track = belongsTo(TrackRecord.self)

    /// A request for the analysed track.
    var track: QueryInterfaceRequest<TrackRecord> {
        request(for: TrackAudioFeatureRecord.track)
    }
}
