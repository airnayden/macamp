// MetadataWriting — the write-back metadata abstraction + its value/error types.
//
// `MetadataWriting` is the write-side mirror of ``MetadataReading``: a narrow,
// `Sendable` seam between callers (a tag-editor view model, a batch retag job)
// and a tag-writing backend. Production code uses ``SFBMetadataWriter`` (real
// files through SFBAudioEngine / TagLib); tests use ``FakeMetadataWriter`` (an
// in-memory recorder, no files). Both speak the ``WritableMetadata`` value type,
// so callers never see SFB types and every failure is a typed
// ``MetadataWriteError`` — never a raw backend `NSError`.
//
// The Metadata module added writing here on top of its original read-only scope
// (see ``MetadataReading``). Writing is ALWAYS atomic and ALWAYS off the audio
// thread — see ``SFBMetadataWriter`` for the temp-copy + rename contract.
//
// This file imports only Foundation; it MUST NOT import AppKit or UIKit
// (PlayerCore portability invariant).
import Foundation

/// A `Sendable` writer that applies a ``WritableMetadata`` patch to an audio file.
///
/// Conformers are value types (or `Sendable` reference types) so one writer can
/// serve any number of URLs. The single throwing method never traps and never
/// throws a raw backend error — only a typed ``MetadataWriteError``. On any error
/// the target file is left byte-for-byte unchanged (atomic write contract).
public protocol MetadataWriting: Sendable {
    /// Applies `metadata` to the tags of the file at `url`.
    ///
    /// Patch semantics: a non-`nil` field is written; a `nil` field is left
    /// exactly as it was on disk (so writing only `title` never clears `artist`).
    /// See ``WritableMetadata`` for the per-field rules, including artwork.
    ///
    /// - Throws: ``MetadataWriteError`` for read-only, missing, unsupported or
    ///   unwritable input. The file is unmodified whenever this throws.
    func writeMetadata(_ metadata: WritableMetadata, to url: URL) throws
}

// MARK: - WritableMetadata value type

/// The mutable subset of an audio file's tags MacAMP can write back.
///
/// This is deliberately narrower than the read-side ``TrackMetadata``: it carries
/// only user-editable tag fields (no stream properties like sample rate, no
/// computed sort keys).
///
/// The four ReplayGain fields are the one *measured* rather than typed group. They
/// are here so an explicit, user-invoked "Write ReplayGain Tags" action can push
/// scanner output onto disk through the same atomic write path; nothing writes
/// them automatically. Route that action through ``ReplayGainTagWriter`` rather
/// than constructing the patch by hand — it holds the per-format refusal policy
/// this type deliberately does not.
///
/// **Patch semantics.** Every field is optional and `nil` means *leave the
/// on-disk value unchanged*. This makes a partial edit safe: writing
/// `WritableMetadata(title: "New")` rewrites only the title and preserves artist,
/// album, artwork and everything else. (There is intentionally no "clear this
/// scalar tag" affordance in v1 — clearing artwork is the one exception, below.)
public struct WritableMetadata: Sendable, Equatable {
    /// New track title, or `nil` to leave it unchanged.
    public var title: String?
    /// New track / primary artist, or `nil` to leave it unchanged.
    public var artist: String?
    /// New album title, or `nil` to leave it unchanged.
    public var album: String?
    /// New album artist, or `nil` to leave it unchanged.
    public var albumArtist: String?
    /// New genre, or `nil` to leave it unchanged.
    public var genre: String?
    /// New composer, or `nil` to leave it unchanged.
    public var composer: String?
    /// New release year (written as a 4-digit release-date tag), or `nil`.
    public var year: Int?
    /// New 1-based track number, or `nil` to leave it unchanged.
    public var trackNumber: Int?
    /// New 1-based disc number, or `nil` to leave it unchanged.
    public var discNumber: Int?

    /// Embedded cover art to write.
    ///
    /// Tri-state, distinct from the scalar fields:
    /// - `nil` — leave the file's existing pictures untouched.
    /// - `[]` — remove every embedded picture.
    /// - `[a, b, …]` — replace all pictures with exactly these.
    public var artwork: [EmbeddedArtwork]?

    /// `REPLAYGAIN_TRACK_GAIN`, in dB relative to the reference loudness.
    public var replayGainTrackGain: Double?
    /// `REPLAYGAIN_TRACK_PEAK`, linear sample/true peak (`1.0` == full scale).
    public var replayGainTrackPeak: Double?
    /// `REPLAYGAIN_ALBUM_GAIN`, in dB relative to the reference loudness.
    public var replayGainAlbumGain: Double?
    /// `REPLAYGAIN_ALBUM_PEAK`, linear peak across the album.
    public var replayGainAlbumPeak: Double?

    public init(
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        albumArtist: String? = nil,
        genre: String? = nil,
        composer: String? = nil,
        year: Int? = nil,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        artwork: [EmbeddedArtwork]? = nil,
        replayGainTrackGain: Double? = nil,
        replayGainTrackPeak: Double? = nil,
        replayGainAlbumGain: Double? = nil,
        replayGainAlbumPeak: Double? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.genre = genre
        self.composer = composer
        self.year = year
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.artwork = artwork
        self.replayGainTrackGain = replayGainTrackGain
        self.replayGainTrackPeak = replayGainTrackPeak
        self.replayGainAlbumGain = replayGainAlbumGain
        self.replayGainAlbumPeak = replayGainAlbumPeak
    }

    /// `true` when no field would change anything (every scalar is `nil` and
    /// artwork is `nil`). A writer may short-circuit such a no-op.
    public var isEmpty: Bool {
        title == nil && artist == nil && album == nil && albumArtist == nil
            && genre == nil && composer == nil && year == nil
            && trackNumber == nil && discNumber == nil && artwork == nil
            && !hasReplayGain
    }

    /// `true` when at least one of the four ReplayGain fields would be written.
    public var hasReplayGain: Bool {
        replayGainTrackGain != nil || replayGainTrackPeak != nil
            || replayGainAlbumGain != nil || replayGainAlbumPeak != nil
    }
}

// MARK: - Re-import notification

public extension Notification.Name {
    /// Posted by a ``MetadataWriting`` backend AFTER a successful, committed write.
    ///
    /// The caller (library service) observes this to resync the affected DB row
    /// without the Metadata module ever touching the database — the `userInfo`
    /// carries the written file URL under ``metadataDidWriteURLKey``. The folder
    /// watcher should ignore the FSEvents change this write triggers; see
    /// ``MetadataSelfWriteRegistry``.
    static let metadataDidWrite = Notification.Name("com.macamp.metadata.didWrite")
}

/// `userInfo` key (value: `URL`) carried by ``Notification/Name/metadataDidWrite``.
public let metadataDidWriteURLKey = "url"

// MARK: - MetadataWriteError

/// A typed, `Sendable` description of why a tag write could not be committed.
///
/// The write-side mirror of ``MetadataError``. Every failure path in
/// ``SFBMetadataWriter`` surfaces as one of these — the writer never traps, never
/// force-unwraps, and never lets a raw SFBAudioEngine / Foundation `NSError`
/// escape. Whenever any of these is thrown the target file is byte-for-byte
/// unchanged (the atomic temp-copy + rename guarantees rollback).
public enum MetadataWriteError: Error, Sendable, Equatable {
    /// Nothing exists at the URL to write to.
    case fileNotFound(url: URL)
    /// The file exists but is not writable by this process (e.g. mode `0444`),
    /// so it is rejected up front and never copied or touched.
    case readOnlyFile(url: URL)
    /// The containing directory (or the OS) denied the write — a temp sibling
    /// could not be created or the atomic rename was refused (`EACCES`/`EPERM`).
    case permissionDenied(url: URL)
    /// The format cannot carry writable tags (Shorten, tracker modules, …) or its
    /// extension is not in the writable allow-list. The file is never touched.
    case unsupportedFormat(url: URL)
    /// The backend read or wrote the working copy but failed (malformed tag
    /// stream, codec write error). The original is left intact.
    case writeFailed(url: URL, reason: String)

    /// The file the failure relates to, for diagnostics and UI reporting.
    public var url: URL {
        switch self {
        case let .fileNotFound(url),
             let .readOnlyFile(url),
             let .permissionDenied(url),
             let .unsupportedFormat(url),
             let .writeFailed(url, _):
            url
        }
    }
}

extension MetadataWriteError: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .fileNotFound(url):
            "no file to write at \(url.lastPathComponent)"
        case let .readOnlyFile(url):
            "file is read-only: \(url.lastPathComponent)"
        case let .permissionDenied(url):
            "permission denied writing \(url.lastPathComponent)"
        case let .unsupportedFormat(url):
            "format does not support tag writing: \(url.lastPathComponent)"
        case let .writeFailed(url, reason):
            "failed to write \(url.lastPathComponent): \(reason)"
        }
    }
}

extension MetadataWriteError: LocalizedError {
    public var errorDescription: String? {
        description
    }
}
