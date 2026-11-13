// LibraryHygieneService+Duplicates — "the library holds this recording twice".
//
// ── THE RULE ───────────────────────────────────────────────────────────────────
//
// Three conjuncts, all required:
//
//   normalized title AND artist are equal
//   AND |durationA − durationB| <= 2 s
//   AND |sizeA − sizeB| / max(sizeA, sizeB) <= 5%
//
// A row missing duration or file size therefore NEVER groups — a conjunct that
// cannot be evaluated cannot be satisfied. That is the deliberate bias of this
// whole analyzer: a missed duplicate costs the listener nothing, while a false one
// proposes dropping a playlist entry for a song that is genuinely a different
// recording (a live take, a radio edit, a remaster). Ambiguity resolves to "not a
// duplicate", every time.
//
// Normalization is `SortKey.sortKey(for:)` — the SAME fold the library sorts by, so
// "Café" matches "Cafe" and "The Beatles" matches "Beatles" exactly as the browse
// list already believes they do. A second, private fold here would be free to drift
// out of agreement with what the listener sees.
//
// ── WHAT A GROUP PROPOSES ──────────────────────────────────────────────────────
//
// Nothing on disk. A group carries the playlists that list the recording MORE THAN
// ONCE, and the membership those playlists would have instead — first occurrence
// kept, later ones dropped. Both copies stay in the library and on disk; the
// listener decides if and when a file goes, and this layer cannot express it.
import Foundation
import Metadata
import Persistence

/// A grouped set of same-recording rows, before playlist membership is attached.
struct DuplicateCandidate {
    let canonical: HygieneTrack
    let duplicates: [HygieneTrack]

    var trackIds: Set<Int64> {
        Set([canonical.trackId] + duplicates.map(\.trackId))
    }
}

// MARK: - Public entry point

public extension LibraryHygieneService {
    func duplicateGroups(profileId: Int64, limit: Int) async throws -> [DuplicateGroup] {
        let scanned = try await scan(profileId: profileId)
        let candidates = Self.duplicateCandidates(in: scanned, limit: limit)
        guard !candidates.isEmpty else { return [] }
        let memberships = try await playlistMemberships(profileId: profileId)
        return candidates.map { Self.group($0, memberships: memberships) }
    }
}

// MARK: - Grouping (pure)

extension LibraryHygieneService {
    /// Buckets by normalized title+artist, then groups within each bucket.
    ///
    /// The bucket is the cheap pre-filter that keeps this from being a cross
    /// product: the expensive pairwise duration/size test only ever runs against
    /// rows that already agree on title and artist, and a bucket bigger than
    /// ``maxBucketSize`` is skipped outright.
    static func duplicateCandidates(
        in scanned: [HygieneScannedTrack],
        limit: Int
    ) -> [DuplicateCandidate] {
        var buckets: [String: [HygieneScannedTrack]] = [:]
        for row in scanned {
            guard let key = bucketKey(row) else { continue }
            buckets[key, default: []].append(row)
        }
        let candidates = buckets.values
            .filter { $0.count > 1 && $0.count <= maxBucketSize }
            .flatMap(groupBucket)
            .sorted { $0.canonical.trackId < $1.canonical.trackId }
        return Array(candidates.prefix(InsightPaging.cap(limit, ceiling: maxFindings)))
    }

    /// `sortKey(title) ⑟ sortKey(artist)`, or `nil` when either is absent — an
    /// untitled or unattributed row is never grouped with anything.
    ///
    /// The separator is a control character no tag realistically contains, so
    /// `("A B", "C")` and `("A", "B C")` cannot collide on one key.
    static func bucketKey(_ row: HygieneScannedTrack) -> String? {
        guard let title = row.track.title, let artist = row.track.artistName else { return nil }
        return SortKey.sortKey(for: title) + "\u{1}" + SortKey.sortKey(for: artist)
    }

    /// Groups one title+artist bucket, id-ascending.
    ///
    /// Matching is against the CANONICAL row, never transitive: if A matches B and B
    /// matches C but A does not match C, the group is {A, B} and C is left alone.
    /// Single-linkage chaining would let a run of 1.9-second steps merge two files
    /// whose runtimes differ by a minute.
    static func groupBucket(_ bucket: [HygieneScannedTrack]) -> [DuplicateCandidate] {
        let rows = bucket.sorted { $0.track.trackId < $1.track.trackId }
        var consumed = Set<Int64>()
        var candidates: [DuplicateCandidate] = []
        for (index, row) in rows.enumerated() where !consumed.contains(row.track.trackId) {
            let matched = rows[rows.index(after: index)...]
                .filter { !consumed.contains($0.track.trackId) && isSameRecording(row, $0) }
            guard !matched.isEmpty else { continue }
            consumed.insert(row.track.trackId)
            for match in matched {
                consumed.insert(match.track.trackId)
            }
            candidates.append(
                DuplicateCandidate(canonical: row.track, duplicates: matched.map(\.track))
            )
        }
        return candidates
    }

    /// The duration and file-size conjuncts. Callers have already established that
    /// the two rows agree on normalized title and artist.
    static func isSameRecording(_ lhs: HygieneScannedTrack, _ rhs: HygieneScannedTrack) -> Bool {
        guard let leftDuration = lhs.duration, let rightDuration = rhs.duration,
              abs(leftDuration - rightDuration) <= durationTolerance
        else { return false }
        guard let leftSize = lhs.fileSize, let rightSize = rhs.fileSize else { return false }
        let largest = Double(max(leftSize, rightSize))
        guard largest > 0 else { return false }
        return abs(Double(leftSize - rightSize)) / largest <= fileSizeTolerance
    }
}

// MARK: - Playlist membership

extension LibraryHygieneService {
    /// The membership of this profile's playlists, keyed by playlist id.
    ///
    /// Reads ONE page of ``maxScannedPlaylists`` playlists — that page IS the bound,
    /// so a profile with a thousand playlists costs the same as one with fifty — and
    /// at most ``maxMembershipPages`` membership pages each.
    func playlistMemberships(profileId: Int64) async throws -> [Int64: [Int64]] {
        let page = try await playlistPage(profileId: profileId)
        var memberships: [Int64: [Int64]] = [:]
        for playlist in page.items {
            guard let playlistId = playlist.id else { continue }
            memberships[playlistId] = try await membership(playlistId: playlistId)
        }
        return memberships
    }

    /// `playlistsPage` has no async twin, so it runs off the calling actor the way
    /// every other sync repository read in `Services` does.
    private func playlistPage(profileId: Int64) async throws -> Page<PlaylistRecord, String> {
        let playlists = playlists
        let limit = Self.maxScannedPlaylists
        return try await Task.detached(priority: .utility) {
            try playlists.playlistsPage(profileId: profileId, after: nil, limit: limit)
        }.value
    }

    private func membership(playlistId: Int64) async throws -> [Int64]? {
        var trackIds: [Int64] = []
        var cursor: PageCursor<Int>?
        var pages = 0
        repeat {
            let page = try await playlists.playlistTracksPage(
                playlistId: playlistId,
                after: cursor,
                limit: Self.membershipPageLimit
            )
            trackIds.append(contentsOf: page.items.compactMap(\.track.id))
            cursor = page.nextCursor
            pages += 1
        } while cursor != nil && pages < Self.maxMembershipPages
        guard cursor == nil else {
            return nil
        }
        return trackIds
    }

    /// Attaches the playlists that list the recording more than once.
    static func group(
        _ candidate: DuplicateCandidate,
        memberships: [Int64: [Int64]]
    ) -> DuplicateGroup {
        let groupIds = candidate.trackIds
        let cleanups = memberships.keys
            .sorted()
            .compactMap { playlistId -> DuplicatePlaylistCleanup? in
                guard let current = memberships[playlistId] else { return nil }
                let proposed = keepingFirstMember(of: groupIds, in: current)
                guard proposed.count < current.count else { return nil }
                return DuplicatePlaylistCleanup(
                    playlistId: playlistId,
                    currentTrackIds: current,
                    proposedTrackIds: proposed
                )
            }
        return DuplicateGroup(
            canonical: candidate.canonical,
            duplicates: candidate.duplicates,
            playlistCleanups: cleanups
        )
    }

    /// The membership with every group member after the first dropped — so the
    /// playlist still plays the song, once, exactly where the listener put it.
    static func keepingFirstMember(of groupIds: Set<Int64>, in membership: [Int64]) -> [Int64] {
        var kept: [Int64] = []
        var seenMember = false
        for trackId in membership {
            if groupIds.contains(trackId) {
                guard !seenMember else { continue }
                seenMember = true
            }
            kept.append(trackId)
        }
        return kept
    }
}
