// OnlineMetadataFetching — the online metadata-lookup seam + its result value type.
//
// The metadata-side analogue of ``OnlineLyricsFetching``: a narrow, `Sendable`
// seam between callers (the tag editor's "Auto-fill" action, a future enrichment
// service) and an online metadata database. Production code uses
// ``MusicBrainzClient`` (real `URLSession`, the MusicBrainz web service); tests and
// previews use ``MockMetadataFetcher`` so **no live network request is ever made
// off the production path**.
//
// This file imports only Foundation; it MUST NOT import AppKit or UIKit
// (PlayerCore portability invariant).
import Foundation

// MARK: - MetadataLookupResult value type

/// A single best-match metadata record resolved from an online database.
///
/// Every field is optional: an online match rarely fills all of them, and a caller
/// (e.g. fill-missing-only auto-fill) populates only the fields it currently lacks.
/// This is deliberately the read-side shape the UI consumes — it is NOT the
/// write-side ``WritableMetadata`` (which carries patch semantics + artwork bytes).
public struct MetadataLookupResult: Sendable, Equatable {
    /// Recording / track title.
    public var title: String?
    /// Credited track artist (the joined artist-credit phrase).
    public var artist: String?
    /// Album / release title.
    public var album: String?
    /// Album artist, when the release credits one distinctly.
    public var albumArtist: String?
    /// Primary genre (the highest-weighted curated genre or folksonomy tag).
    public var genre: String?
    /// Release year (Gregorian).
    public var year: Int?
    /// 1-based track number within its disc.
    public var trackNumber: Int?
    /// 1-based disc number within the release.
    public var discNumber: Int?
    /// Front cover-art URL, when one can be resolved.
    public var artworkURL: URL?
    /// MusicBrainz recording MBID, used to drive a follow-up composer lookup.
    /// Not display copy, so it is excluded from ``isEmpty``.
    public var recordingID: String?

    public init(
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        albumArtist: String? = nil,
        genre: String? = nil,
        year: Int? = nil,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        artworkURL: URL? = nil,
        recordingID: String? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.genre = genre
        self.year = year
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.artworkURL = artworkURL
        self.recordingID = recordingID
    }

    /// `true` when no display field carries a value (``recordingID`` aside), so a
    /// caller can treat the result as "no usable match" even if a record returned.
    public var isEmpty: Bool {
        title == nil && artist == nil && album == nil && albumArtist == nil
            && genre == nil && year == nil && trackNumber == nil
            && discNumber == nil && artworkURL == nil
    }
}

// MARK: - Lookup protocol

/// Resolves one best-match metadata record for a track from an online database.
///
/// Production uses ``MusicBrainzClient``; tests/previews use ``MockMetadataFetcher``
/// so no live network call is made off the production path.
public protocol OnlineMetadataFetching: Sendable {
    /// Looks up the best match for the given identifying fields.
    ///
    /// - Returns: the best match, or `nil` when the service has no match.
    /// - Throws: a transport / decoding error — never for a plain "no match".
    func lookup(
        artist: String?,
        title: String?,
        album: String?,
        duration: TimeInterval?
    ) async throws -> MetadataLookupResult?

    /// Resolves the composer credited to the work behind a recording MBID
    /// (``MetadataLookupResult/recordingID``).
    ///
    /// - Returns: the composer name, or `nil` when none is credited / resolvable.
    /// - Throws: a transport / decoding error — never for a plain "no match".
    func lookupComposer(recordingID: String) async throws -> String?
}

public extension OnlineMetadataFetching {
    /// Default: no composer source. Backends that can resolve one override this.
    func lookupComposer(recordingID _: String) async throws -> String? {
        nil
    }
}
