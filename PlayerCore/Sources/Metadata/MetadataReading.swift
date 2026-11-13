// MetadataReading — the read-only metadata abstraction + its value type.
//
// `MetadataReading` is the narrow seam between callers and a tag-reading
// backend: production code uses ``SFBMetadataReader`` (real files through
// SFBAudioEngine / TagLib) while tests use ``FakeMetadataReader`` (deterministic
// in-memory values, no files). Both vend a ``TrackMetadata`` value type, so the
// library importer and the tests are written once against this protocol and
// never see SFB types directly.
//
// The module is READ-ONLY by design (v1 scope): there is no write-back path.
// Every textual value the readers produce is NFC-normalised; the sort-key
// properties on ``TrackMetadata`` are derived on demand via ``SortKey``.
//
// This file imports only Foundation; it MUST NOT import AppKit or UIKit
// (PlayerCore portability invariant).
import Foundation

/// A `Sendable` reader that extracts ``TrackMetadata`` from an audio file.
///
/// Conformers are stateless value types (so a single reader can serve any number
/// of URLs concurrently). The single throwing method never traps and never
/// throws a raw backend error — only a typed ``MetadataError``.
public protocol MetadataReading: Sendable {
    /// Reads tags + stream properties from `url`.
    ///
    /// - Throws: ``MetadataError`` for unreadable, unsupported or corrupt input.
    func readMetadata(from url: URL) throws -> TrackMetadata
}

// MARK: - TrackMetadata value type

/// The read-only metadata MacAMP extracts from one audio file.
///
/// All textual values are stored **NFC-normalised** with blank tags collapsed to
/// `nil` (the initialiser enforces this via ``SortKey/normalizedOrNil(_:)``), so
/// equality and ordering never depend on the source's Unicode normal form. The
/// four `sort*` properties are *computed* — always consistent with their backing
/// value and never stale.
public struct TrackMetadata: Sendable, Equatable {
    /// Track title (NFC-normalised, `nil` when absent/blank).
    public var title: String?
    /// Track / primary artist.
    public var artist: String?
    /// Album title.
    public var album: String?
    /// Album artist (the "compilation" / box-set grouping artist).
    public var albumArtist: String?
    /// Genre.
    public var genre: String?
    /// Composer.
    public var composer: String?

    /// Release year (Gregorian), parsed from a year or full ISO date tag.
    public var year: Int?
    /// 1-based track number within its disc.
    public var trackNumber: Int?
    /// Total tracks on the disc, when tagged.
    public var trackTotal: Int?
    /// 1-based disc number within a multi-disc set.
    public var discNumber: Int?
    /// Total discs in the set, when tagged.
    public var discTotal: Int?

    /// Stream duration in seconds.
    public var duration: TimeInterval?
    /// Average bitrate in kbps.
    public var bitrate: Double?
    /// Sample rate in Hz.
    public var sampleRate: Double?
    /// Bit depth (bits per sample), `nil` for lossy / inherently-floating codecs.
    public var bitDepth: Int?
    /// Channel count.
    public var channelCount: Int?

    /// Embedded cover art / pictures (may be empty). Bytes are carried verbatim;
    /// decoding to an image is the Artwork module's job, never this reader's.
    public var artwork: [EmbeddedArtwork]
    /// Embedded unsynchronised lyrics (ID3 `USLT` / Vorbis `LYRICS`), if present.
    public var lyrics: String?
    /// ReplayGain loudness tags, or `nil` when the file carries none.
    public var replayGain: ReplayGain?

    /// Article-stripped, folded sort key for ``title`` (e.g. `"beatles"`).
    public var sortTitle: String? {
        SortKey.sortKeyOrNil(title)
    }

    /// Article-stripped, folded sort key for ``artist``.
    public var sortArtist: String? {
        SortKey.sortKeyOrNil(artist)
    }

    /// Article-stripped, folded sort key for ``album``.
    public var sortAlbum: String? {
        SortKey.sortKeyOrNil(album)
    }

    /// Article-stripped, folded sort key for ``albumArtist``.
    public var sortAlbumArtist: String? {
        SortKey.sortKeyOrNil(albumArtist)
    }

    /// `true` when the file carried at least one embedded picture.
    public var hasArtwork: Bool {
        !artwork.isEmpty
    }

    /// Builds a value, NFC-normalising every textual field so the invariant holds
    /// regardless of construction path (production reader or test double).
    public init(
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        albumArtist: String? = nil,
        genre: String? = nil,
        composer: String? = nil,
        year: Int? = nil,
        trackNumber: Int? = nil,
        trackTotal: Int? = nil,
        discNumber: Int? = nil,
        discTotal: Int? = nil,
        duration: TimeInterval? = nil,
        bitrate: Double? = nil,
        sampleRate: Double? = nil,
        bitDepth: Int? = nil,
        channelCount: Int? = nil,
        artwork: [EmbeddedArtwork] = [],
        lyrics: String? = nil,
        replayGain: ReplayGain? = nil
    ) {
        self.title = SortKey.normalizedOrNil(title)
        self.artist = SortKey.normalizedOrNil(artist)
        self.album = SortKey.normalizedOrNil(album)
        self.albumArtist = SortKey.normalizedOrNil(albumArtist)
        self.genre = SortKey.normalizedOrNil(genre)
        self.composer = SortKey.normalizedOrNil(composer)
        self.year = year
        self.trackNumber = trackNumber
        self.trackTotal = trackTotal
        self.discNumber = discNumber
        self.discTotal = discTotal
        self.duration = duration
        self.bitrate = bitrate
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.channelCount = channelCount
        self.artwork = artwork
        self.lyrics = SortKey.normalizedOrNil(lyrics)
        self.replayGain = replayGain
    }
}

// MARK: - Embedded artwork

/// One embedded picture carried verbatim from the file's tag stream.
public struct EmbeddedArtwork: Sendable, Equatable {
    /// The raw image bytes (PNG/JPEG/…), exactly as stored in the tag.
    public var data: Data
    /// MIME type declared by the tag (e.g. `image/jpeg`), when present.
    public var mimeType: String?
    /// The picture's role (front cover, back cover, artist, …).
    public var type: ArtworkType
    /// Free-text description the tag attached to the picture, if any.
    public var pictureDescription: String?

    public init(data: Data, mimeType: String? = nil, type: ArtworkType = .other, pictureDescription: String? = nil) {
        self.data = data
        self.mimeType = mimeType
        self.type = type
        self.pictureDescription = SortKey.normalizedOrNil(pictureDescription)
    }
}

/// The role of an embedded picture, numbered per the ID3v2 `APIC` picture-type
/// table (which SFBAudioEngine's attached-picture type mirrors).
public enum ArtworkType: Int, Sendable, Equatable, CaseIterable {
    case other = 0
    case fileIcon = 1
    case otherFileIcon = 2
    case frontCover = 3
    case backCover = 4
    case leafletPage = 5
    case media = 6
    case leadArtist = 7
    case artist = 8
    case conductor = 9
    case band = 10
    case composer = 11
    case lyricist = 12
    case recordingLocation = 13
    case duringRecording = 14
    case duringPerformance = 15
    case movieScreenCapture = 16
    case colouredFish = 17
    case illustration = 18
    case bandLogo = 19
    case publisherLogo = 20
}

// MARK: - ReplayGain

/// ReplayGain loudness-normalisation tags read from a file.
///
/// Gains are in dB (apply as a level offset); peaks are linear sample values in
/// `0...1` (the highest absolute sample, used to avoid clipping when a positive
/// gain is applied). Any field may be `nil` when the file omits that tag.
public struct ReplayGain: Sendable, Equatable {
    /// Reference loudness the gains target, in dB (conventionally 89 dB SPL).
    public var referenceLoudness: Double?
    /// Track gain in dB (per-track normalisation).
    public var trackGain: Double?
    /// Track peak as a linear sample value in `0...1`.
    public var trackPeak: Double?
    /// Album gain in dB (album-coherent normalisation).
    public var albumGain: Double?
    /// Album peak as a linear sample value in `0...1`.
    public var albumPeak: Double?

    public init(
        referenceLoudness: Double? = nil,
        trackGain: Double? = nil,
        trackPeak: Double? = nil,
        albumGain: Double? = nil,
        albumPeak: Double? = nil
    ) {
        self.referenceLoudness = referenceLoudness
        self.trackGain = trackGain
        self.trackPeak = trackPeak
        self.albumGain = albumGain
        self.albumPeak = albumPeak
    }

    /// `true` when no ReplayGain field was present (so the reader stores `nil`).
    public var isEmpty: Bool {
        referenceLoudness == nil && trackGain == nil && trackPeak == nil
            && albumGain == nil && albumPeak == nil
    }
}

// MARK: - FakeMetadataReader

/// A ``MetadataReading`` that returns fixed, deterministic metadata instead of
/// reading files — the test/double counterpart to ``SFBMetadataReader``.
///
/// The default value models a "The Beatles / Abbey Road" track so callers can
/// assert article-stripping (`sortArtist == "beatles"`) without binary fixtures.
/// Chosen extensions can be made to throw, so ``MetadataError`` handling is
/// testable deterministically.
public struct FakeMetadataReader: MetadataReading {
    /// The metadata every successful read returns.
    public let metadata: TrackMetadata
    /// Extensions that ``readMetadata(from:)`` rejects as `.unsupportedFormat`.
    public let unsupportedExtensions: Set<String>
    /// Extensions that ``readMetadata(from:)`` rejects as `.corruptedFile`.
    public let corruptExtensions: Set<String>

    public init(
        metadata: TrackMetadata = FakeMetadataReader.defaultMetadata,
        unsupportedExtensions: Set<String> = [],
        corruptExtensions: Set<String> = []
    ) {
        self.metadata = metadata
        self.unsupportedExtensions = unsupportedExtensions
        self.corruptExtensions = corruptExtensions
    }

    public func readMetadata(from url: URL) throws -> TrackMetadata {
        let ext = url.pathExtension.lowercased()
        if unsupportedExtensions.contains(ext) {
            throw MetadataError.unsupportedFormat(url: url)
        }
        if corruptExtensions.contains(ext) {
            throw MetadataError.corruptedFile(url: url, reason: "injected by FakeMetadataReader")
        }
        return metadata
    }

    /// A deterministic, fully-populated fixture (leading-article artist + album,
    /// embedded art, and ReplayGain) for tests that need a realistic value.
    public static let defaultMetadata = TrackMetadata(
        title: "Come Together",
        artist: "The Beatles",
        album: "Abbey Road",
        albumArtist: "The Beatles",
        genre: "Rock",
        composer: "Lennon-McCartney",
        year: 1969,
        trackNumber: 1,
        trackTotal: 17,
        discNumber: 1,
        discTotal: 1,
        duration: 259.0,
        bitrate: 1024,
        sampleRate: 44100,
        bitDepth: 16,
        channelCount: 2,
        artwork: [EmbeddedArtwork(data: Data([0xFF, 0xD8, 0xFF]), mimeType: "image/jpeg", type: .frontCover)],
        lyrics: "Here come old flat top",
        replayGain: ReplayGain(
            referenceLoudness: 89,
            trackGain: -7.5,
            trackPeak: 0.98,
            albumGain: -8.2,
            albumPeak: 0.99
        )
    )
}
