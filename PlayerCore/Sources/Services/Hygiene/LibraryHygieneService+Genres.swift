// LibraryHygieneService+Genres — "this genre is spelled four ways".
//
// The library's genre filter is a list of DISTINCT STRINGS, so "Hip Hop",
// "Hip-Hop" and "hip hop" are three chips that each hide two thirds of the same
// music. This analyzer finds those splits and names the spelling to settle on.
//
// ── HOW A CANONICAL SPELLING IS CHOSEN ─────────────────────────────────────────
//
// The most-used variant wins, ties broken by the lexicographically smaller
// spelling. Both halves matter:
//
//   * MOST-USED, not "prettiest" — the canonical spelling is always one the library
//     already contains, so accepting the proposal never introduces a spelling the
//     listener has not seen. A title-cased rendering of the fold key ("Hiphop")
//     would be a fourth variant, and would mangle "R&B" into "Rb".
//   * A TIE-BREAK AT ALL — dictionary iteration is unordered, so without a total
//     rule the same library could propose a different canonical spelling on each
//     run, and a preview would stop matching the apply that follows it.
//
// Only the MINORITY spellings are proposed for retagging; the tracks that already
// carry the canonical spelling are counted, never rewritten.
import Foundation

public extension LibraryHygieneService {
    func genreClusters(profileId: Int64, limit: Int) async throws -> [GenreCluster] {
        let scanned = try await scan(profileId: profileId)
        return Self.clusters(in: scanned, limit: limit)
    }
}

extension LibraryHygieneService {
    /// Buckets by ``GenreFolding`` key; a bucket carrying more than one spelling is
    /// a cluster. Ordered by canonical spelling, so the list is total.
    static func clusters(in scanned: [HygieneScannedTrack], limit: Int) -> [GenreCluster] {
        var buckets: [String: [String: [HygieneTrack]]] = [:]
        for row in scanned {
            guard let genre = row.genre, let key = GenreFolding.key(for: genre) else { continue }
            buckets[key, default: [:]][genre, default: []].append(row.track)
        }
        let clusters = buckets.values
            .filter { $0.count > 1 }
            .compactMap(cluster)
            .sorted { $0.canonicalGenre < $1.canonicalGenre }
        return Array(clusters.prefix(InsightPaging.cap(limit, ceiling: maxFindings)))
    }

    /// Builds one cluster from a fold bucket's spellings.
    static func cluster(_ spellings: [String: [HygieneTrack]]) -> GenreCluster? {
        guard let canonical = spellings.max(by: canonicalOrder) else { return nil }
        let variants = spellings
            .filter { $0.key != canonical.key }
            .map { GenreVariant(genre: $0.key, tracks: $0.value.sorted { $0.trackId < $1.trackId }) }
            .sorted { $0.genre < $1.genre }
        guard !variants.isEmpty else { return nil }
        return GenreCluster(
            canonicalGenre: canonical.key,
            canonicalTrackCount: canonical.value.count,
            variants: variants
        )
    }

    /// `max` picks the LAST element under this ordering, so "greater" must mean
    /// "better canonical": more tracks, and on a tie the smaller spelling.
    static func canonicalOrder(
        _ lhs: (key: String, value: [HygieneTrack]),
        _ rhs: (key: String, value: [HygieneTrack])
    ) -> Bool {
        if lhs.value.count != rhs.value.count {
            return lhs.value.count < rhs.value.count
        }
        return lhs.key > rhs.key
    }
}
