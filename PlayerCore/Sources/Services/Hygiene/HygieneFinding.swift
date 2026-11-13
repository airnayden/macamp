// HygieneFinding — what the library hygiene analyzers OBSERVE, never what they do.
//
// A finding is evidence, not an instruction. Every type in this file is an inert
// value: nothing here can reach a repository, a metadata writer or the filesystem,
// and no analyzer that produces one performs a write. Turning a finding into
// something the listener can accept happens one layer up, in
// `AssistantViewModel+Hygiene` — which files an ``AIProposal`` that only an
// explicit `apply` ever executes.
//
// ── THE ONE RULE THAT SHAPES THESE TYPES ───────────────────────────────────────
//
// NOTHING HERE CAN EXPRESS DELETING A FILE. A duplicate does not carry "the file
// to remove"; it carries the playlists that list the same song twice and the
// membership those playlists would have instead. That is the strongest form the
// "never destroy user data" invariant can take: the deletion is not forbidden by
// discipline, it is UNSPELLABLE in the vocabulary the analyzers speak — the same
// reason the availability state machine rewrites a column rather than deleting a
// row when media vanishes.
//
// Every collection here is ordered deterministically (by id, or by spelling) so a
// finding renders, prints and compares identically run to run.
//
// This file imports only Foundation; it MUST NOT import AppKit or UIKit
// (PlayerCore portability invariant).
import Foundation

// MARK: - Shared reference

/// The minimum a finding needs to name one library row: its id, the file a tag
/// patch would be written to, and the text a review list shows.
///
/// Deliberately NOT a `TrackRecord`. A finding travels to the presentation layer
/// and into a proposal preview; carrying the whole row would invite a consumer to
/// read a field the analyzer never checked — including the frozen `track.*` user-
/// state columns, which nothing may read.
public struct HygieneTrack: Sendable, Equatable, Hashable {
    /// The library row's id.
    public let trackId: Int64
    /// The absolute path of the source file — the ONLY path a finding carries, and
    /// never an instrumental-cache path.
    public let filePath: String
    /// The live title, as the player would show it.
    public let title: String?
    /// The live artist, as the player would show it.
    public let artistName: String?

    public init(trackId: Int64, filePath: String, title: String?, artistName: String?) {
        self.trackId = trackId
        self.filePath = filePath
        self.title = title
        self.artistName = artistName
    }

    /// The file a tag patch would be written to.
    public var fileURL: URL {
        URL(fileURLWithPath: filePath)
    }
}

// MARK: - Duplicates

/// Two or more library rows that are the same recording, and the playlists that
/// consequently list that recording more than once.
///
/// ``canonical`` is the KEEPER — the lowest track id, i.e. the row that has been in
/// the library longest. It is not "the better file": the analyzer compares
/// normalized title/artist, duration and file size, which cannot rank quality. The
/// keeper only decides which row the finding describes the others against.
public struct DuplicateGroup: Sendable, Equatable {
    /// The row the group is described against. Lowest id of the group.
    public let canonical: HygieneTrack
    /// The other rows in the group, id-ascending. Never empty.
    public let duplicates: [HygieneTrack]
    /// The playlists that list this recording more than once, id-ascending.
    ///
    /// EMPTY is the normal case: two copies of a song on disk are not a problem
    /// until a playlist plays it twice. An empty array means the group is worth
    /// reviewing but has no membership to fix — and maps to no proposal at all.
    public let playlistCleanups: [DuplicatePlaylistCleanup]

    public init(
        canonical: HygieneTrack,
        duplicates: [HygieneTrack],
        playlistCleanups: [DuplicatePlaylistCleanup]
    ) {
        self.canonical = canonical
        self.duplicates = duplicates
        self.playlistCleanups = playlistCleanups
    }

    /// Every row in the group, canonical first then the duplicates in id order.
    public var tracks: [HygieneTrack] {
        [canonical] + duplicates
    }

    /// Every row's id, in the same order as ``tracks``.
    public var trackIds: [Int64] {
        tracks.map(\.trackId)
    }
}

/// One playlist's redundant membership, expressed as the membership it has now and
/// the membership it would have instead.
///
/// The proposal shape upstream (`PlaylistOrganizeDiff`) derives its additions /
/// removals / moves from exactly these two lists, so a preview can never describe a
/// change other than the one that would be written.
///
/// ``proposedTrackIds`` keeps the FIRST-POSITIONED member of the group and drops
/// every later one, so the playlist still plays the song — once, where the listener
/// originally put it.
public struct DuplicatePlaylistCleanup: Sendable, Equatable {
    public let playlistId: Int64
    /// The playlist's membership as it stands, in playing order.
    public let currentTrackIds: [Int64]
    /// The membership after dropping the redundant entries, in playing order.
    public let proposedTrackIds: [Int64]

    public init(playlistId: Int64, currentTrackIds: [Int64], proposedTrackIds: [Int64]) {
        self.playlistId = playlistId
        self.currentTrackIds = currentTrackIds
        self.proposedTrackIds = proposedTrackIds
    }

    /// How many entries the cleanup would drop.
    public var removedCount: Int {
        currentTrackIds.count - proposedTrackIds.count
    }
}

// MARK: - Genre clusters

/// Several spellings of one genre, and the spelling the analyzer would settle on.
///
/// This is a TEXT-VARIANT problem ("Hip Hop" / "Hip-Hop" / "hip hop"), distinct
/// from the ID3 numeric-code problem `GenreNormalizer` solves ("(17)" → "Rock").
/// Both run: the raw tag is resolved by `GenreNormalizer` first, and the resolved
/// display text is then folded by ``GenreFolding`` — so a numerically-coded row
/// clusters with its free-text neighbours instead of forming a variant of its own.
public struct GenreCluster: Sendable, Equatable {
    /// The spelling the cluster would standardise on: the most-used variant, ties
    /// broken by the lexicographically smaller spelling so the choice is stable.
    public let canonicalGenre: String
    /// How many tracks already carry ``canonicalGenre``.
    public let canonicalTrackCount: Int
    /// The minority spellings, spelling-ascending. Never empty — a single spelling
    /// is not a cluster.
    public let variants: [GenreVariant]

    public init(canonicalGenre: String, canonicalTrackCount: Int, variants: [GenreVariant]) {
        self.canonicalGenre = canonicalGenre
        self.canonicalTrackCount = canonicalTrackCount
        self.variants = variants
    }

    /// Every track that would be retagged, in variant then id order.
    public var tracksToRetag: [HygieneTrack] {
        variants.flatMap(\.tracks)
    }
}

/// One minority spelling and the tracks that carry it.
public struct GenreVariant: Sendable, Equatable {
    /// The spelling as it appears on the files today.
    public let genre: String
    /// The tracks carrying it, id-ascending.
    public let tracks: [HygieneTrack]

    public init(genre: String, tracks: [HygieneTrack]) {
        self.genre = genre
        self.tracks = tracks
    }
}

// MARK: - Metadata gaps

/// A tag field a triage list reports as absent.
///
/// Three fields, chosen because each one silently breaks a browsing surface:
/// `genre` empties the genre filter, `year` empties the decade facets, and
/// `albumArtist` splits a compilation across as many album rows as it has artists.
public enum MetadataGapField: String, Sendable, Equatable, CaseIterable {
    case genre
    case year
    case albumArtist
}

/// One track missing at least one of ``MetadataGapField``'s fields.
///
/// ``suggestedAlbumArtist`` is the ONLY fix this layer will offer, and it is
/// deliberately the most conservative one available: when a track has an artist but
/// no album artist, the artist is what the album artist would be for every
/// single-artist album — which is nearly all of them. `genre` and `year` have no
/// local evidence to derive them from, so they are reported for REVIEW and nothing
/// is invented; guessing a year would put a number on a file that nothing measured.
public struct MetadataGap: Sendable, Equatable {
    public let track: HygieneTrack
    /// The absent fields, in ``MetadataGapField/allCases`` order. Never empty.
    public let missingFields: [MetadataGapField]
    /// The album artist the track's own artist implies, or `nil` when the album
    /// artist is present or the artist is missing too.
    public let suggestedAlbumArtist: String?

    public init(
        track: HygieneTrack,
        missingFields: [MetadataGapField],
        suggestedAlbumArtist: String?
    ) {
        self.track = track
        self.missingFields = missingFields
        self.suggestedAlbumArtist = suggestedAlbumArtist
    }

    /// Whether this gap carries a fix the listener could accept, as opposed to a
    /// row that is only worth reading.
    public var isActionable: Bool {
        suggestedAlbumArtist != nil
    }
}

// MARK: - Umbrella

/// One thing the hygiene pass noticed about the library.
///
/// Repo-internal, so every switch over it must be exhaustive with no `default:` —
/// a fourth analyzer becomes a compile error at every consumer rather than a case
/// that silently produces no proposal.
public enum HygieneFinding: Sendable, Equatable {
    case duplicate(DuplicateGroup)
    case genreCluster(GenreCluster)
    case metadataGap(MetadataGap)
}
