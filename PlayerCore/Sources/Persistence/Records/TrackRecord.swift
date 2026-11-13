import Foundation
import GRDB

/// A single audio track backed by a file on disk (or an external volume).
///
/// Maps the `track` table. `artistName` / `albumTitle` are **denormalised**
/// copies of the related artist/album text, kept so the FTS5 external-content
/// search index (Task 12) can be backed by the `track` table alone.
public struct TrackRecord: Codable, Sendable, Equatable, Hashable {
    /// Auto-incremented rowid primary key. `nil` until the record is inserted.
    public var id: Int64?
    /// Absolute file path. `UNIQUE NOT NULL`.
    public var filePath: String
    /// Display title.
    public var title: String?
    /// Locale-aware sorting key.
    public var sortTitle: String?
    /// Denormalised artist display name.
    public var artistName: String?
    /// Denormalised album display title.
    public var albumTitle: String?
    /// Owning artist (`ON DELETE SET NULL`).
    public var artistId: Int64?
    /// Owning album (`ON DELETE SET NULL`).
    public var albumId: Int64?
    /// 1-based track number within its disc.
    public var trackNumber: Int?
    /// 1-based disc number within its album.
    public var discNumber: Int?
    /// Duration in seconds.
    public var duration: Double?
    /// Nominal bitrate in bits/second.
    public var bitrate: Int?
    /// Sample rate in Hz.
    public var sampleRate: Int?
    /// Bit depth in bits per sample.
    public var bitDepth: Int?
    /// File size in bytes.
    public var fileSize: Int64?
    /// File modification time (seconds since the reference date / epoch).
    public var mtime: Double?
    /// Backing-file availability. Never a `Bool` — three states. Defaults to
    /// ``Availability/present``.
    public var availability: Availability
    /// When the track was added to the library.
    public var dateAdded: Double?
    /// Number of completed plays. Defaults to `0`.
    public var playCount: Int
    /// ReplayGain track gain in dB.
    public var replaygainTrackGain: Double?
    /// ReplayGain track peak (linear, 0...1+).
    public var replaygainTrackPeak: Double?
    /// ReplayGain album gain in dB.
    public var replaygainAlbumGain: Double?
    /// ReplayGain album peak (linear, 0...1+).
    public var replaygainAlbumPeak: Double?
    /// Display genre, normalised at import via `GenreNormalizer`. Added in v5;
    /// `nil` for rows imported before v5 until their next re-scan.
    public var genre: String?
    /// Album-artist / compilation credit. Added in v6; `nil` until re-scanned.
    public var albumArtist: String?
    /// Composer credit. Added in v6; `nil` until re-scanned.
    public var composer: String?
    /// Release year. Added in v6; `nil` until re-scanned.
    public var year: Int?
    /// Channel count (1 = mono, 2 = stereo, …). Added in v6; `nil` until re-scanned.
    public var channelCount: Int?
    /// User-defined display position within a folder view. Added in v7.
    public var customPosition: Int?
    public var listenedCount: Int
    /// Whether the user marked this track a favourite. Added in v8; stored as
    /// INTEGER 0/1 (GRDB maps `Bool` automatically). Defaults to `false`.
    public var isFavourite: Bool
    /// Absolute path of the `.cue` sidecar this row's segment was named by, or
    /// `nil` for an ordinary whole-file row. Added in v20.
    ///
    /// The sheet path — **never** this row's ``filePath``, which always names the
    /// AUDIO file. A multi-FILE sheet spreads one `cueSheetPath` across several
    /// `filePath` values, which is why album pooling groups on this column.
    public var cueSheetPath: String?
    /// First frame of this cue segment, or ``wholeFileCueStartFrame`` (`-1`) for
    /// an ordinary whole-file row. `NOT NULL`. Added in v20.
    ///
    /// Half of the row's identity: v20 replaced the v1 `UNIQUE(filePath)` with
    /// `UNIQUE(filePath, cueStartFrame)`, so ``filePath`` alone no longer
    /// identifies one row. Use ``identity`` for any single-row lookup.
    public var cueStartFrame: Int64
    /// One-past-the-last frame of this cue segment (**EXCLUSIVE**), or `nil` for
    /// "to the end of the audio file". Added in v20.
    public var cueEndFrame: Int64?
    /// Whether a `.cue` sheet superseded this whole-file row. Added in v20.
    ///
    /// Set by the scanner when a sheet appears for a file the library had already
    /// imported whole. The row is **retained, never deleted** — deleting it would
    /// cascade `playlistTrack`/`profileTrackState`/`folderTrackOrder` and orphan
    /// the bare-`trackId` stats rows. A suppressed row keeps working everywhere it
    /// is already referenced; only the library browse listings and search results
    /// hide it. See ``CueSuppression`` for the exhaustive call-site contract.
    public var cueSuppressed: Bool

    public init(
        id: Int64? = nil,
        filePath: String,
        title: String? = nil,
        sortTitle: String? = nil,
        artistName: String? = nil,
        albumTitle: String? = nil,
        artistId: Int64? = nil,
        albumId: Int64? = nil,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        duration: Double? = nil,
        bitrate: Int? = nil,
        sampleRate: Int? = nil,
        bitDepth: Int? = nil,
        fileSize: Int64? = nil,
        mtime: Double? = nil,
        availability: Availability = .present,
        dateAdded: Double? = nil,
        playCount: Int = 0,
        replaygainTrackGain: Double? = nil,
        replaygainTrackPeak: Double? = nil,
        replaygainAlbumGain: Double? = nil,
        replaygainAlbumPeak: Double? = nil,
        genre: String? = nil,
        albumArtist: String? = nil,
        composer: String? = nil,
        year: Int? = nil,
        channelCount: Int? = nil,
        customPosition: Int? = nil,
        listenedCount: Int = 0,
        isFavourite: Bool = false,
        cueSheetPath: String? = nil,
        cueStartFrame: Int64 = TrackRecord.wholeFileCueStartFrame,
        cueEndFrame: Int64? = nil,
        cueSuppressed: Bool = false
    ) {
        self.id = id
        self.filePath = filePath
        self.title = title
        self.sortTitle = sortTitle
        self.artistName = artistName
        self.albumTitle = albumTitle
        self.artistId = artistId
        self.albumId = albumId
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.duration = duration
        self.bitrate = bitrate
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.fileSize = fileSize
        self.mtime = mtime
        self.availability = availability
        self.dateAdded = dateAdded
        self.playCount = playCount
        self.replaygainTrackGain = replaygainTrackGain
        self.replaygainTrackPeak = replaygainTrackPeak
        self.replaygainAlbumGain = replaygainAlbumGain
        self.replaygainAlbumPeak = replaygainAlbumPeak
        self.genre = genre
        self.albumArtist = albumArtist
        self.composer = composer
        self.year = year
        self.channelCount = channelCount
        self.customPosition = customPosition
        self.listenedCount = listenedCount
        self.isFavourite = isFavourite
        self.cueSheetPath = cueSheetPath
        self.cueStartFrame = cueStartFrame
        self.cueEndFrame = cueEndFrame
        self.cueSuppressed = cueSuppressed
    }
}

extension TrackRecord: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "track"

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let filePath = Column(CodingKeys.filePath)
        public static let title = Column(CodingKeys.title)
        public static let sortTitle = Column(CodingKeys.sortTitle)
        public static let artistName = Column(CodingKeys.artistName)
        public static let albumTitle = Column(CodingKeys.albumTitle)
        public static let artistId = Column(CodingKeys.artistId)
        public static let albumId = Column(CodingKeys.albumId)
        public static let trackNumber = Column(CodingKeys.trackNumber)
        public static let discNumber = Column(CodingKeys.discNumber)
        public static let duration = Column(CodingKeys.duration)
        public static let bitrate = Column(CodingKeys.bitrate)
        public static let sampleRate = Column(CodingKeys.sampleRate)
        public static let bitDepth = Column(CodingKeys.bitDepth)
        public static let fileSize = Column(CodingKeys.fileSize)
        public static let mtime = Column(CodingKeys.mtime)
        public static let availability = Column(CodingKeys.availability)
        public static let dateAdded = Column(CodingKeys.dateAdded)
        public static let playCount = Column(CodingKeys.playCount)
        public static let replaygainTrackGain = Column(CodingKeys.replaygainTrackGain)
        public static let replaygainTrackPeak = Column(CodingKeys.replaygainTrackPeak)
        public static let replaygainAlbumGain = Column(CodingKeys.replaygainAlbumGain)
        public static let replaygainAlbumPeak = Column(CodingKeys.replaygainAlbumPeak)
        public static let genre = Column(CodingKeys.genre)
        public static let albumArtist = Column(CodingKeys.albumArtist)
        public static let composer = Column(CodingKeys.composer)
        public static let year = Column(CodingKeys.year)
        public static let channelCount = Column(CodingKeys.channelCount)
        public static let customPosition = Column(CodingKeys.customPosition)
        public static let listenedCount = Column(CodingKeys.listenedCount)
        public static let isFavourite = Column(CodingKeys.isFavourite)
        public static let cueSheetPath = Column(CodingKeys.cueSheetPath)
        public static let cueStartFrame = Column(CodingKeys.cueStartFrame)
        public static let cueEndFrame = Column(CodingKeys.cueEndFrame)
        public static let cueSuppressed = Column(CodingKeys.cueSuppressed)
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Display

public extension TrackRecord {
    /// The tag title, or the file's own name when the track is untagged.
    ///
    /// A **display** projection only: ``title`` stays exactly as the tag wrote it
    /// (the tag editor must keep showing an empty field for an untagged track),
    /// ``sortTitle`` is untouched, and the FTS5 index never sees this value.
    ///
    /// The stem strips exactly **one** extension and is otherwise verbatim —
    /// `"a.b.mp3"` → `"a.b"`, and no underscore substitution or case folding, unlike
    /// the metadata guesser. A leading dot is part of the name, not an extension
    /// separator, so `".hidden"` → `".hidden"`.
    var displayTitle: String {
        let tagged = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard tagged.isEmpty else { return tagged }
        return Self.filenameStem(ofPath: filePath)
    }

    static func filenameStem(ofPath path: String) -> String {
        let component = (path as NSString).lastPathComponent
        let stem = (component as NSString).deletingPathExtension
        return stem.isEmpty ? component : stem
    }
}

// MARK: - Associations

public extension TrackRecord {
    /// The track's artist (`track.artistId → artist.id`).
    static let artist = belongsTo(ArtistRecord.self)
    /// The track's album (`track.albumId → album.id`).
    static let album = belongsTo(AlbumRecord.self)

    /// A request for this track's artist.
    var artist: QueryInterfaceRequest<ArtistRecord> {
        request(for: TrackRecord.artist)
    }

    /// A request for this track's album.
    var album: QueryInterfaceRequest<AlbumRecord> {
        request(for: TrackRecord.album)
    }
}
