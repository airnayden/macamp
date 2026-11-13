// ListeningStatsViewModel+Replayed — the most-replayed rows, ranked on exactly the
// basis ``ListeningDigest/mostReplayed`` uses.
//
// The digest already answers "which tracks do you obsessively replay", but it answers
// it in portable terms: snapshot identity, no row ids, no drawable curve. The screen
// needs the same list PLUS the live library row behind each entry and the normalized
// intensities the scrubber overlay draws. Recomputing the ranking here is what makes
// the two lists line up — so it is recomputed from the same inputs, through the same
// helpers, with the same comparator:
//
//   * the same scan — `allSegmentHeat` paged to exhaustion, no new heat API;
//   * the same floor — ``ReplayHeatAnalysis/hasTrustworthyShape(totalPasses:buckets:)``;
//   * the same scoring — ``ReplayHeatAnalysis`` for affinity, totals and clusters;
//   * the same comparator — affinity ↓, committed passes ↓, then the total tie-break
//     string built from the identical fields and the identical `\u{1}` separator;
//   * the same cap — ``ListeningDigestBuilder/replayEntityLimit``.
//
// Mirroring rather than reusing is deliberate: `ListeningDigestBuilder`'s ranking is
// `private` because it is an implementation detail of a *portable* digest, and
// widening it to hand back row ids and Float curves would leak this screen's needs
// into the archive format. `ListeningStatsViewModelTests` locks the two sequences
// together instead, including a case where a LOW-pass/HIGH-affinity row must outrank a
// HIGH-pass/LOW-affinity one — so a near-miss re-implementation fails loudly.
import Foundation
import Persistence
import Services

/// One most-replayed row: the digest's own view of a heatmap, plus what the screen
/// needs on top of it.
public struct ReplayedRow: Identifiable, Sendable, Equatable {
    /// The heatmap's track backlink. One row per `(profile, track)`, so it is unique
    /// within a load.
    public var id: Int64 {
        trackId
    }

    /// The capture-time snapshot identity — the same value the digest's matching
    /// ``ReplayHeatDigest/track`` carries.
    public let identity: ListeningTrackIdentity
    /// Best-effort backlink to the library row.
    public let trackId: Int64
    /// The live library row, or `nil` when the track no longer exists.
    public let resolved: ProfileScopedTrack?
    /// One 0…1 value per relative bucket, or `nil` when there is nothing to draw.
    public let intensities: [Float]?
    /// Committed listening passes folded into this heatmap.
    public let totalPasses: Int
    /// See ``ReplayHeatAnalysis/replayAffinity(_:)``.
    public let replayAffinity: Double

    public init(
        identity: ListeningTrackIdentity,
        trackId: Int64,
        resolved: ProfileScopedTrack?,
        intensities: [Float]?,
        totalPasses: Int,
        replayAffinity: Double
    ) {
        self.identity = identity
        self.trackId = trackId
        self.resolved = resolved
        self.intensities = intensities
        self.totalPasses = totalPasses
        self.replayAffinity = replayAffinity
    }
}

/// A heatmap scored into the digest's own entity, paired with the row id and the
/// drawable curve the digest has no reason to carry — and with the string that makes
/// the ordering total.
struct RankedReplayCandidate {
    /// Exactly the value ``ListeningDigest/mostReplayed`` would hold for this row.
    let entry: ReplayHeatDigest
    let trackId: Int64
    let intensities: [Float]?
    let tieBreak: String
}

extension ListeningStatsViewModel {
    /// Below every printable character, so the joined tie-break orders exactly as the
    /// tuple of its components would. Mirrors `ListeningDigestBuilder.fieldSeparator`.
    nonisolated static let replayFieldSeparator = "\u{1}"

    /// Scans, filters, scores and ranks every one of the profile's heatmaps.
    ///
    /// Paged to exhaustion through the EXISTING `allSegmentHeat` read — the very scan
    /// the digest's `mostReplayed` performs — so the two see the same rows. A row
    /// whose bucket blob will not decode is dropped rather than failing the load: one
    /// corrupt heatmap must not cost the user the whole statistics screen.
    static func rankedReplayCandidates(
        heat: any PlaySegmentHeatRepositoryProviding,
        profileId: Int64
    ) async throws -> [RankedReplayCandidate] {
        var candidates: [RankedReplayCandidate] = []
        var cursor: PageCursor<Int64>?
        repeat {
            let page = try await heat.allSegmentHeat(
                profileId: profileId,
                after: cursor,
                limit: PlaySegmentHeatRepository.fetchLimit
            )
            for record in page.items {
                guard let candidate = makeReplayCandidate(record) else { continue }
                candidates.append(candidate)
            }
            cursor = page.nextCursor
        } while cursor != nil
        return ranked(candidates)
    }

    /// Pairs each ranked candidate with its resolved library row.
    static func makeReplayedRows(
        _ candidates: [RankedReplayCandidate],
        resolved: [Int64: ProfileScopedTrack]
    ) -> [ReplayedRow] {
        candidates.map { candidate in
            ReplayedRow(
                identity: candidate.entry.track,
                trackId: candidate.trackId,
                resolved: resolved[candidate.trackId],
                intensities: candidate.intensities,
                totalPasses: candidate.entry.totalPasses,
                replayAffinity: candidate.entry.replayAffinity
            )
        }
    }
}

// MARK: - Scoring and ordering (mirrors ListeningDigestBuilder)

private extension ListeningStatsViewModel {
    /// Scores one row into the digest's ``ReplayHeatDigest`` shape.
    ///
    /// The intensities come from ``ScrubberHeatViewModel/normalized(_:)-(PlaySegmentHeatRecord?)``
    /// rather than a second normalization written here, so the list and the scrubber
    /// overlay can never disagree about a curve — and so the trust floor is expressed
    /// once, in one predicate.
    ///
    /// `nil` covers both "below the floor" and "the blob would not decode": one
    /// corrupt heatmap must not cost the user the whole statistics screen.
    static func makeReplayCandidate(_ record: PlaySegmentHeatRecord) -> RankedReplayCandidate? {
        guard
            let buckets = try? record.decodedBuckets(),
            ReplayHeatAnalysis.hasTrustworthyShape(totalPasses: record.totalPasses, buckets: buckets)
        else { return nil }
        let entry = ReplayHeatDigest(
            track: ListeningTrackIdentity(
                artistName: record.artistName,
                title: record.title,
                albumTitle: record.albumTitle,
                genre: record.genre
            ),
            durationSeconds: record.durationSeconds,
            totalPasses: record.totalPasses,
            totalListens: ReplayHeatAnalysis.totalCount(buckets),
            replayAffinity: ReplayHeatAnalysis.replayAffinity(buckets),
            clusters: ReplayHeatAnalysis.clusters(buckets)
        )
        return RankedReplayCandidate(
            entry: entry,
            trackId: record.trackId,
            intensities: ScrubberHeatViewModel.normalized(record),
            tieBreak: replayTieBreak(entry)
        )
    }

    /// Every field the entry encodes beyond affinity and passes, joined below the
    /// printable range. Two candidates that still compare equal here are byte-identical
    /// and their relative order cannot change the output.
    static func replayTieBreak(_ entry: ReplayHeatDigest) -> String {
        let clusters = entry.clusters
            .map { "\($0.startPercent)-\($0.endPercent)-\($0.intensity)" }
            .joined(separator: ",")
        return [
            entry.track.identityKey,
            entry.track.artistName ?? "",
            entry.track.title ?? "",
            entry.track.albumTitle ?? "",
            entry.track.genre ?? "",
            "\(entry.durationSeconds)",
            "\(entry.totalListens)",
            clusters,
        ].joined(separator: replayFieldSeparator)
    }

    /// Affinity descending, then committed passes descending, then the total tie-break
    /// ascending — whose first component is the identity key.
    static func ranked(_ candidates: [RankedReplayCandidate]) -> [RankedReplayCandidate] {
        let sorted = candidates.sorted { lhs, rhs in
            if lhs.entry.replayAffinity != rhs.entry.replayAffinity {
                return lhs.entry.replayAffinity > rhs.entry.replayAffinity
            }
            if lhs.entry.totalPasses != rhs.entry.totalPasses {
                return lhs.entry.totalPasses > rhs.entry.totalPasses
            }
            return lhs.tieBreak < rhs.tieBreak
        }
        return Array(sorted.prefix(ListeningDigestBuilder.replayEntityLimit))
    }
}
