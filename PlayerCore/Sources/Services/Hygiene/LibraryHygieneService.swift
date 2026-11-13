// LibraryHygieneService — the three "your library has a wrinkle" analyzers.
//
// Duplicates, genre-spelling clusters and metadata gaps. All three READ ONLY:
// nothing in this file or its extensions opens a write transaction, touches a
// metadata writer, or names a file to delete. They produce ``HygieneFinding``s,
// which `AssistantViewModel+Hygiene` maps to proposals that only an explicit
// `apply` ever executes.
//
// Four rules are load-bearing:
//
//  1. **Only `present` tracks are ever surfaced.** A hygiene finding is a change
//     the listener might accept, and proposing to retag a file that is not there —
//     or to "de-duplicate" a row whose volume is merely unmounted — would be wrong
//     in both directions. `missing` / `externalOffline` rows are dropped in the
//     scan, before any analyzer sees them.
//  2. **Everything is profile-scoped.** The walk is `TrackRepository.tracksPage`,
//     which applies `LibraryVisibility`, and playlist membership is read through
//     the profile-scoped `playlistsPage`. A rival profile's library cannot appear
//     in this profile's findings.
//  3. **Every read is bounded.** The library walk is keyset-paged and stops at
//     ``maxScannedTracks``; the membership walk stops at ``maxScannedPlaylists``
//     playlists and ``maxMembershipPages`` pages each; every output list is capped
//     at ``maxFindings``. There is no unbounded `fetchAll` anywhere.
//  4. **The frozen columns are never read.** The scan takes tag and file facts off
//     `TrackRecord` — never `playCount` / `listenedCount` / `isFavourite` /
//     `customPosition`, which v12 froze.
//
// ── WHY ONE WALK, NOT THREE QUERIES ────────────────────────────────────────────
//
// Each analyzer could have its own SQL: `GROUP BY title`, `SELECT DISTINCT genre`,
// `WHERE genre IS NULL`. They all need the SAME bounded, visibility-scoped,
// availability-filtered row set, so three queries would be three places for that
// bound to drift — and the duplicate rule (normalized title AND duration AND file
// size) is not expressible in SQL anyway without a normalization function SQLite
// does not have. One keyset walk feeds three pure, in-memory analyzers, so the
// bound is stated once and the rules are testable without a database.
import Foundation
import Metadata
import Persistence

// MARK: - Protocol

/// Produces one profile's library hygiene findings. Read-only by construction.
public protocol LibraryHygieneProviding: Sendable {
    /// Recordings the library holds more than once, with the playlists that list
    /// them twice. Empty — never an error — when the library is clean.
    func duplicateGroups(profileId: Int64, limit: Int) async throws -> [DuplicateGroup]

    /// Genres spelled more than one way, with the spelling to settle on.
    func genreClusters(profileId: Int64, limit: Int) async throws -> [GenreCluster]

    /// Tracks missing genre, year or album artist, in library order.
    func metadataGaps(profileId: Int64, limit: Int) async throws -> [MetadataGap]

    /// Every finding in one pass: duplicates, then genre clusters, then gaps.
    func findings(profileId: Int64, limit: Int) async throws -> [HygieneFinding]
}

// MARK: - Service

/// The production ``LibraryHygieneProviding`` over the profile-scoped library.
public struct LibraryHygieneService: LibraryHygieneProviding {
    /// Seconds two runtimes may differ by and still be the same recording. Two rips
    /// of one CD track routinely differ by a frame or two of lead-in.
    public static let durationTolerance: Double = 2
    /// Relative file-size difference two files may show and still be the same
    /// recording — 5%, which spans the same encoder at neighbouring VBR settings
    /// without spanning two different masters.
    public static let fileSizeTolerance: Double = 0.05
    /// Ceiling on any one finding list, and on ``findings(profileId:limit:)``.
    public static let maxFindings = 100
    /// Ceiling on the library rows one pass will look at.
    static let maxScannedTracks = 5000
    /// Ceiling on the playlists the membership walk will read.
    static let maxScannedPlaylists = 50
    /// Ceiling on the membership pages read per playlist.
    static let maxMembershipPages = 10
    /// Rows per membership page.
    static let membershipPageLimit = 200
    /// Ceiling on one normalized-title bucket before it is skipped entirely.
    ///
    /// A bucket is compared pairwise, so a library with hundreds of rows titled
    /// "Track 01" by "Unknown Artist" would otherwise cost a quadratic blow-up on
    /// exactly the rows least likely to be real duplicates.
    static let maxBucketSize = 50

    let tracks: TrackRepository
    let playlists: any PlaylistRepositoryProviding
    let pageSize: Int

    /// - Parameters:
    ///   - tracks: The library. Held concretely for the same reason
    ///     `RediscoveryService` holds it concretely — its profile-scoped reads are
    ///     concrete-extension APIs by repo precedent.
    ///   - playlists: Membership, read through the protocol seam so a Fake can
    ///     stand in.
    ///   - pageSize: Rows per keyset page. A free parameter precisely so a test can
    ///     prove the output does not depend on it.
    public init(
        tracks: TrackRepository,
        playlists: any PlaylistRepositoryProviding,
        pageSize: Int = InsightPaging.defaultPageSize
    ) {
        self.tracks = tracks
        self.playlists = playlists
        self.pageSize = max(1, pageSize)
    }

    /// Convenience over the application database.
    public init(_ appDatabase: AppDatabase, pageSize: Int = InsightPaging.defaultPageSize) {
        self.init(
            tracks: TrackRepository(appDatabase),
            playlists: PlaylistRepository(appDatabase),
            pageSize: pageSize
        )
    }
}

// MARK: - Scanned row

/// One library row reduced to exactly the facts the three analyzers read.
///
/// Module-internal rather than private: the duplicate and genre analyzers live in
/// sibling extension files, and a shared row type is what lets the walk happen once.
struct HygieneScannedTrack {
    let track: HygieneTrack
    let duration: Double?
    let fileSize: Int64?
    /// The display genre after `GenreNormalizer`, blank-mapped to `nil`.
    let genre: String?
    let year: Int?
    /// The album artist, blank-mapped to `nil`.
    let albumArtist: String?
}

// MARK: - The bounded walk

extension LibraryHygieneService {
    /// One keyset-paged, visibility-scoped, `present`-only pass over the library.
    ///
    /// Stops at ``maxScannedTracks`` rows WALKED (not kept), so an unreachable
    /// stretch of library cannot extend the pass.
    func scan(profileId: Int64) async throws -> [HygieneScannedTrack] {
        var scanned: [HygieneScannedTrack] = []
        var walked = 0
        var cursor: PageCursor<String>?
        repeat {
            let page = try await tracks.tracksPage(profileId: profileId, after: cursor, limit: pageSize)
            walked += page.items.count
            for record in page.items {
                guard let row = Self.scannedTrack(record) else { continue }
                scanned.append(row)
            }
            cursor = page.nextCursor
        } while cursor != nil && walked < Self.maxScannedTracks
        return scanned
    }

    /// Reduces one row, or `nil` when it is unusable: no id, or not `present`.
    ///
    /// Blank tags are mapped to `nil` through `SortKey.normalizedOrNil`, so an empty
    /// genre frame reads as the absence it is rather than as a spelling variant.
    static func scannedTrack(_ record: TrackRecord) -> HygieneScannedTrack? {
        guard let trackId = record.id, record.availability == .present else { return nil }
        return HygieneScannedTrack(
            track: HygieneTrack(
                trackId: trackId,
                filePath: record.filePath,
                title: SortKey.normalizedOrNil(record.title),
                artistName: SortKey.normalizedOrNil(record.artistName)
            ),
            duration: record.duration,
            fileSize: record.fileSize,
            genre: SortKey.normalizedOrNil(GenreNormalizer.normalize(record.genre)),
            year: record.year,
            albumArtist: SortKey.normalizedOrNil(record.albumArtist)
        )
    }
}

// MARK: - Metadata gaps

public extension LibraryHygieneService {
    func metadataGaps(profileId: Int64, limit: Int) async throws -> [MetadataGap] {
        let scanned = try await scan(profileId: profileId)
        return Self.gaps(in: scanned, limit: limit)
    }
}

extension LibraryHygieneService {
    /// The gap rows, in library (scan) order — which is the order a triage list
    /// wants, and is already total because the walk is keyset-ordered.
    static func gaps(in scanned: [HygieneScannedTrack], limit: Int) -> [MetadataGap] {
        Array(
            scanned
                .lazy
                .compactMap(gap)
                .prefix(InsightPaging.cap(limit, ceiling: maxFindings))
        )
    }

    /// One row's gap, or `nil` when nothing is missing.
    static func gap(_ row: HygieneScannedTrack) -> MetadataGap? {
        let missing = MetadataGapField.allCases.filter { isMissing($0, in: row) }
        guard !missing.isEmpty else { return nil }
        let suggested = missing.contains(.albumArtist) ? row.track.artistName : nil
        return MetadataGap(track: row.track, missingFields: missing, suggestedAlbumArtist: suggested)
    }

    static func isMissing(_ field: MetadataGapField, in row: HygieneScannedTrack) -> Bool {
        switch field {
        case .genre: row.genre == nil
        case .year: row.year == nil
        case .albumArtist: row.albumArtist == nil
        }
    }
}

// MARK: - Everything at once

public extension LibraryHygieneService {
    /// All three analyzers over ONE walk, capped at `limit` findings in total.
    ///
    /// The category order — duplicates, clusters, gaps — is fixed rather than
    /// interleaved by severity: a stable order is what lets a summary card and the
    /// proposals it files agree with each other across refreshes.
    func findings(profileId: Int64, limit: Int) async throws -> [HygieneFinding] {
        let scanned = try await scan(profileId: profileId)
        let candidates = Self.duplicateCandidates(in: scanned, limit: Self.maxFindings)
        let memberships = candidates.isEmpty
            ? [:]
            : try await playlistMemberships(profileId: profileId)
        var found = candidates
            .map { HygieneFinding.duplicate(Self.group($0, memberships: memberships)) }
        found += Self.clusters(in: scanned, limit: Self.maxFindings).map(HygieneFinding.genreCluster)
        found += Self.gaps(in: scanned, limit: Self.maxFindings).map(HygieneFinding.metadataGap)
        return Array(found.prefix(InsightPaging.cap(limit, ceiling: Self.maxFindings)))
    }
}
