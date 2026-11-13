import Foundation
import GRDB

/// What a ``TrackLoudnessRecord`` was measured from.
///
/// A struct rather than a 4-tuple because SwiftLint's `large_tuple` rule caps tuples
/// at two members, and because the `-1` whole-file sentinel deserves a name.
public struct TrackLoudnessFingerprint: Sendable, Equatable, Hashable {
    /// `cueStartFrame` for a row that describes a whole file rather than a cue segment.
    public static let wholeFileCueStartFrame: Int64 = -1

    /// Size in bytes of the analysed file.
    public var fileSize: Int64
    /// Modification time of the analysed file.
    public var mtime: Double
    /// First frame analysed, or ``wholeFileCueStartFrame`` for a whole file.
    public var cueStartFrame: Int64
    /// Exclusive last frame analysed, or `nil` for "to end of file".
    public var cueEndFrame: Int64?

    public init(
        fileSize: Int64,
        mtime: Double,
        cueStartFrame: Int64 = TrackLoudnessFingerprint.wholeFileCueStartFrame,
        cueEndFrame: Int64? = nil
    ) {
        self.fileSize = fileSize
        self.mtime = mtime
        self.cueStartFrame = cueStartFrame
        self.cueEndFrame = cueEndFrame
    }

    /// Whether this fingerprint describes a whole file rather than a cue segment.
    public var isWholeFile: Bool {
        cueStartFrame == Self.wholeFileCueStartFrame && cueEndFrame == nil
    }
}

/// Cached BS.1770-4 loudness for one track or cue segment.
///
/// Maps the `trackLoudness` table, whose primary key is the caller-supplied `trackId`
/// — there is **no** separate `id` column. Because that key is not an auto-increment
/// rowid, this conforms to `PersistableRecord` (not `MutablePersistableRecord`): there
/// is nothing to write back after insert, exactly like ``TrackAudioFeatureRecord``,
/// ``ProfileTrackStateRecord`` and ``ProfilePlaybackStateRecord``.
///
/// A caller must treat a row whose ``fingerprint`` no longer matches what it is about
/// to analyse — or whose ``analysisVersion`` predates the current analyser — as absent
/// and recompute it.
///
/// ``integratedLUFS`` is `Double?` and `nil` is a **real answer**: no 400 ms block
/// cleared the −70 LKFS absolute gate. Never substitute `0` — there is no reference
/// level to normalise against. ``truePeak`` is always present because a true peak is
/// always computable; silence measures linear `0`.
public struct TrackLoudnessRecord: Codable, Sendable, Equatable, Hashable {
    /// Analysed track (`ON DELETE CASCADE`) and the table's whole primary key.
    public var trackId: Int64
    /// Integrated loudness in LUFS, or `nil` when nothing cleared the absolute gate.
    public var integratedLUFS: Double?
    /// Sample-peak-over-oversampled true peak, linear (`1.0` == full scale).
    public var truePeak: Double
    /// Pooled album loudness in LUFS, or `nil` until the whole album group pooled.
    public var albumLUFS: Double?
    /// Maximum true peak across the album group, linear, or `nil` until it pooled.
    public var albumPeak: Double?
    /// ``BlockLoudnessHistogram`` blob of absolute-gate-passing block loudnesses.
    public var blockPowersHistogram: Data?
    /// Analyser schema version that produced these values.
    public var analysisVersion: Int
    /// Size in bytes of the analysed file; part of the staleness fingerprint.
    public var fileSize: Int64
    /// Modification time of the analysed file; part of the staleness fingerprint.
    public var mtime: Double
    /// First frame analysed; `-1` means whole file. Part of the fingerprint.
    public var cueStartFrame: Int64
    /// Exclusive last frame analysed; `nil` means end of file. Part of the fingerprint.
    public var cueEndFrame: Int64?
    /// When the analysis ran, as seconds since the Unix epoch.
    public var computedAt: Double

    public init(
        trackId: Int64,
        integratedLUFS: Double?,
        truePeak: Double,
        albumLUFS: Double? = nil,
        albumPeak: Double? = nil,
        blockPowersHistogram: Data? = nil,
        analysisVersion: Int,
        fingerprint: TrackLoudnessFingerprint,
        computedAt: Double
    ) {
        self.trackId = trackId
        self.integratedLUFS = integratedLUFS
        self.truePeak = truePeak
        self.albumLUFS = albumLUFS
        self.albumPeak = albumPeak
        self.blockPowersHistogram = blockPowersHistogram
        self.analysisVersion = analysisVersion
        fileSize = fingerprint.fileSize
        mtime = fingerprint.mtime
        cueStartFrame = fingerprint.cueStartFrame
        cueEndFrame = fingerprint.cueEndFrame
        self.computedAt = computedAt
    }
}

// MARK: - Derived reads

public extension TrackLoudnessRecord {
    /// What this row was measured from.
    var fingerprint: TrackLoudnessFingerprint {
        TrackLoudnessFingerprint(
            fileSize: fileSize,
            mtime: mtime,
            cueStartFrame: cueStartFrame,
            cueEndFrame: cueEndFrame
        )
    }

    /// Whether this row can still be served for `fingerprint` at `analysisVersion`.
    func isFresh(for fingerprint: TrackLoudnessFingerprint, analysisVersion: Int) -> Bool {
        self.analysisVersion == analysisVersion && self.fingerprint == fingerprint
    }

    /// The decoded block-loudness histogram, or `nil` when the row carries none.
    func decodedHistogram() throws -> [UInt32]? {
        guard let blockPowersHistogram else { return nil }
        return try BlockLoudnessHistogram.decode(blockPowersHistogram)
    }

    /// Throws ``BlockLoudnessHistogramError/invalidHistogramSize(expected:actual:)``
    /// unless ``blockPowersHistogram`` is absent or well-formed.
    func validate() throws {
        guard let blockPowersHistogram else { return }
        try BlockLoudnessHistogram.validate(blockPowersHistogram)
    }
}

extension TrackLoudnessRecord: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "trackLoudness"

    public enum Columns {
        public static let trackId = Column(CodingKeys.trackId)
        public static let integratedLUFS = Column(CodingKeys.integratedLUFS)
        public static let truePeak = Column(CodingKeys.truePeak)
        public static let albumLUFS = Column(CodingKeys.albumLUFS)
        public static let albumPeak = Column(CodingKeys.albumPeak)
        public static let blockPowersHistogram = Column(CodingKeys.blockPowersHistogram)
        public static let analysisVersion = Column(CodingKeys.analysisVersion)
        public static let fileSize = Column(CodingKeys.fileSize)
        public static let mtime = Column(CodingKeys.mtime)
        public static let cueStartFrame = Column(CodingKeys.cueStartFrame)
        public static let cueEndFrame = Column(CodingKeys.cueEndFrame)
        public static let computedAt = Column(CodingKeys.computedAt)
    }

    /// GRDB calls this before every insert and update, so a misaligned histogram can
    /// never reach the database — whichever write path a caller takes.
    public func willSave(_: Database) throws {
        try validate()
    }
}

// MARK: - Associations

public extension TrackLoudnessRecord {
    /// The analysed track (`trackLoudness.trackId → track.id`).
    static let track = belongsTo(TrackRecord.self)

    /// A request for the analysed track.
    var track: QueryInterfaceRequest<TrackRecord> {
        request(for: TrackLoudnessRecord.track)
    }
}
