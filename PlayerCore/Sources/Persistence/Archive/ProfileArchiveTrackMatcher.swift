// ProfileArchiveTrackMatcher — resolves archived track identities to LOCAL rowids.
//
// This is the hard part of importing a profile. A `.macampprofile` carries no row
// ids, because the exporting machine's ids mean nothing here: reusing them would
// either violate `profileTrackState`'s foreign key to the local `track` table or —
// worse — silently attach a heatmap to an UNRELATED local song that happens to own
// the same rowid. So every archived row names its track by snapshot, and this type
// re-resolves that snapshot against the local library.
//
// The matching pass is one bounded, keyset-paginated scan of `track`: the matcher is
// seeded with the archive's identities (already in memory) and each local row is
// OFFERED to it, so memory is O(archive) and the database work is O(library) with a
// hard page ceiling — never a per-identity query and never a full table load.
import Foundation
import GRDB

/// Matches archived track identities against the local library.
///
/// ## The rule
/// Candidates must agree EXACTLY on the case-folded `(artist, title, album)` triple
/// and, when both sides know it, on duration to within
/// ``durationTolerance``. **Exactly one** surviving candidate is a match; zero,
/// several, or "too many to tell" all resolve to *unmatched*, which is a safe,
/// lossless outcome:
/// * a `playEvent` keeps its full snapshot and just carries `trackId = NULL`;
/// * a `playSegmentHeat` row gets a synthetic negative id, so it still feeds every
///   digest facet without ever attaching to the wrong song;
/// * a `profileTrackState` counter row is dropped and reported (its foreign key
///   demands a real local track).
///
/// - Note: The key is case-folded with `String.lowercased()`, which is the
///   locale-INDEPENDENT Unicode default mapping — deliberately not
///   `lowercased(with:)`, which would fold differently under e.g. a Turkish locale.
///   This key is an internal matching detail and is never serialized, so it is free
///   to differ from the digest's `identityKey`.
public struct ProfileArchiveTrackMatcher: Sendable {
    /// How far two durations may differ and still describe the same song. Two rips
    /// of one track rarely agree to the millisecond.
    public static let durationTolerance: Double = 1.0

    /// Candidates kept per identity before the identity is written off as hopelessly
    /// ambiguous. A song present this many times under one exact name is a library
    /// the matcher cannot disambiguate, and guessing would mis-attach history.
    public static let maximumCandidatesPerIdentity = 8

    private struct Candidate {
        let trackId: Int64
        let durationSeconds: Double?
    }

    private var candidates: [String: [Candidate]]
    private var ambiguous: Set<String>

    /// Seeds the matcher with the identities an archive references. Local rows whose
    /// key is not seeded are ignored outright, which is what keeps memory bounded by
    /// the archive rather than by the library.
    public init(identities: some Sequence<ProfileArchiveTrackIdentity>) {
        var seeded: [String: [Candidate]] = [:]
        for identity in identities {
            seeded[Self.matchKey(identity)] = []
        }
        candidates = seeded
        ambiguous = []
    }

    /// Whether the matcher has anything to look for. `false` means the caller can
    /// skip the local-library scan entirely.
    public var isEmpty: Bool {
        candidates.isEmpty
    }

    /// Offers one local track row as a possible match.
    public mutating func offer(_ track: ProfileArchiveLocalTrack) {
        let key = Self.matchKey(
            artistName: track.artistName,
            title: track.title,
            albumTitle: track.albumTitle
        )
        guard var bucket = candidates[key] else { return }
        guard bucket.count < Self.maximumCandidatesPerIdentity else {
            ambiguous.insert(key)
            return
        }
        bucket.append(Candidate(trackId: track.trackId, durationSeconds: track.durationSeconds))
        candidates[key] = bucket
    }

    /// The local rowid this identity resolves to, or `nil` when it is unmatched.
    public func localTrackId(for identity: ProfileArchiveTrackIdentity) -> Int64? {
        let key = Self.matchKey(identity)
        guard !ambiguous.contains(key), let bucket = candidates[key] else { return nil }
        let viable = bucket.filter {
            Self.durationsAgree($0.durationSeconds, identity.durationSeconds)
        }
        guard viable.count == 1, let only = viable.first else { return nil }
        return only.trackId
    }

    // MARK: - Pure helpers

    /// The case-folded `artist|title|album` key two rows must share to be candidates.
    public static func matchKey(_ identity: ProfileArchiveTrackIdentity) -> String {
        matchKey(
            artistName: identity.artistName,
            title: identity.title,
            albumTitle: identity.albumTitle
        )
    }

    /// The case-folded `artist|title|album` key, built from loose parts.
    public static func matchKey(artistName: String?, title: String?, albumTitle: String?) -> String {
        let artist = (artistName ?? "").lowercased()
        let name = (title ?? "").lowercased()
        let album = (albumTitle ?? "").lowercased()
        return "\(artist)|\(name)|\(album)"
    }

    /// Whether two durations are close enough to describe the same song. An unknown
    /// duration on either side is not evidence of a mismatch, so it never rejects.
    public static func durationsAgree(_ lhs: Double?, _ rhs: Double?) -> Bool {
        guard let lhs, let rhs else { return true }
        return abs(lhs - rhs) <= durationTolerance
    }
}

// MARK: - The local row the matcher consumes

/// The four identity columns plus the rowid, read from the LOCAL `track` table.
///
/// Deliberately a narrow projection: `filePath` is not selected, so an import pass
/// never even loads a path into memory.
public struct ProfileArchiveLocalTrack: Sendable, Equatable, Hashable, FetchableRecord, Decodable {
    public var trackId: Int64
    public var title: String?
    public var artistName: String?
    public var albumTitle: String?
    public var durationSeconds: Double?

    public init(
        trackId: Int64,
        title: String? = nil,
        artistName: String? = nil,
        albumTitle: String? = nil,
        durationSeconds: Double? = nil
    ) {
        self.trackId = trackId
        self.title = title
        self.artistName = artistName
        self.albumTitle = albumTitle
        self.durationSeconds = durationSeconds
    }

    /// The projection this type decodes. Keyset-paginated on the rowid by the caller.
    static let selectSQL = """
    SELECT id AS trackId, title, artistName, albumTitle, duration AS durationSeconds
    FROM track
    WHERE id > ?
    ORDER BY id
    LIMIT ?
    """
}
