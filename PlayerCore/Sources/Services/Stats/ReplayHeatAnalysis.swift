// ReplayHeatAnalysis — turning a 100-bucket replay heatmap into two readable facts.
//
// `playSegmentHeat` stores, per profile and track, how many times each 1% slice of
// the song was actually heard. Three questions are worth answering from it:
//
//  1. **Where are the hooks?** A *cluster* is a maximal run of at least two adjacent
//     buckets that are each at least 60% as hot as the track's hottest bucket. Two
//     buckets is the shortest run that means "a passage" rather than "a scrub
//     landed here", and a relative threshold is what lets a track played 3 times and
//     one played 300 times be described on the same scale.
//  2. **How obsessive is the listening?** ``replayAffinity(_:)`` is the share of all
//     listening that fell in the track's hottest decile of buckets. A listener who
//     plays a song front to back scores ≈ 0.1 (ten of a hundred equal buckets); one
//     who loops a chorus scores far higher. "Top decile" means the ten highest-count
//     buckets, NOT the last ten positions in the song.
//  3. **Is there enough here to say anything?** ``hasTrustworthyShape(totalPasses:buckets:)``
//     is the single floor BOTH display surfaces apply — the scrubber overlay and the
//     digest's Most Replayed ranking — so the two can never disagree about which
//     tracks have a shape worth drawing.
//
// Everything here is a pure function of the bucket array, so the same heatmap yields
// the same clusters and the same affinity on every machine. Counts are summed as
// `UInt64` because a bucket saturates at `UInt32.max` and a hundred of them would
// overflow `UInt32`.
import Foundation

/// A hot passage of a track, expressed in percent of its duration.
///
/// The range is half-open: `startPercent ..< endPercent`, so a cluster covering
/// buckets 30 and 31 reads `30 ..< 32`.
public struct ReplayCluster: Codable, Sendable, Equatable, Hashable {
    /// First percent of the track the cluster covers, `0 ... 99`.
    public var startPercent: Int
    /// One past the last percent the cluster covers, `1 ... 100`.
    public var endPercent: Int
    /// Mean bucket count across the cluster over the track's hottest bucket,
    /// rounded to ``StatsRounding/fractionDigits``. Always within `0.6 ... 1`.
    public var intensity: Double

    public init(startPercent: Int, endPercent: Int, intensity: Double) {
        self.startPercent = startPercent
        self.endPercent = endPercent
        self.intensity = intensity
    }
}

/// Cluster detection and replay-affinity scoring over a bucket heatmap.
public enum ReplayHeatAnalysis {
    /// Share of the track's hottest bucket a bucket must reach to join a cluster.
    public static let clusterThresholdShare = 0.6

    /// Adjacent hot buckets needed before a run counts as a passage.
    public static let minimumClusterLength = 2

    /// Clusters reported per track.
    public static let clusterLimit = 3

    /// Committed listening passes that on their own make a heatmap's shape trustworthy.
    public static let minimumTrustedPasses = 3

    /// Times a single 1% slice must have been heard for the shape to be trustworthy
    /// without three separate sittings.
    public static let minimumTrustedPeakCount: UInt32 = 3

    /// Whether a heatmap carries enough data for its shape to be worth showing.
    ///
    /// The floor's intent has always been "enough data that the shape is
    /// trustworthy", and a pass count alone measures that badly. One pass is one
    /// FLUSH, not one listen: a single fifty-minute sitting in which the listener
    /// rewound to the same passage four or five times writes bucket counts of 4–6
    /// against `totalPasses == 1`. That is the archetypal replay signal, and a
    /// passes-only gate hid it — the case this predicate exists to admit.
    ///
    /// So either half satisfies the intent independently: three separate sittings
    /// (the shape was corroborated across occasions), OR some 1% slice that was
    /// genuinely heard three times (the shape was corroborated within one). Only a
    /// heatmap that clears neither is treated as noise.
    public static func hasTrustworthyShape(totalPasses: Int, buckets: [UInt32]) -> Bool {
        if totalPasses >= minimumTrustedPasses { return true }
        return (buckets.max() ?? 0) >= minimumTrustedPeakCount
    }

    /// Total listens across every bucket.
    ///
    /// `UInt64` because each bucket saturates at `UInt32.max`; a hundred of them
    /// would wrap a `UInt32` accumulator and read as "barely played".
    public static func totalCount(_ buckets: [UInt32]) -> UInt64 {
        buckets.reduce(UInt64(0)) { $0 + UInt64($1) }
    }

    /// Share of all listening that fell in the track's hottest decile of buckets,
    /// rounded to ``StatsRounding/fractionDigits``.
    ///
    /// Ties need no tie-break: the metric sums *counts*, so which of two equal
    /// buckets is picked cannot change the total.
    public static func replayAffinity(_ buckets: [UInt32]) -> Double {
        let total = totalCount(buckets)
        guard total > 0 else { return 0 }
        let decile = max(1, buckets.count / 10)
        let hottest = buckets.sorted(by: >).prefix(decile).reduce(UInt64(0)) { $0 + UInt64($1) }
        return StatsRounding.ratio(Double(hottest), over: Double(total))
    }

    /// The track's hottest passages, at most `limit` of them.
    ///
    /// Ordered by ``ReplayCluster/intensity`` descending, then by
    /// ``ReplayCluster/startPercent`` ascending — a total order, since two clusters
    /// cannot share a start.
    public static func clusters(_ buckets: [UInt32], limit: Int = clusterLimit) -> [ReplayCluster] {
        guard limit > 0, let peak = buckets.max(), peak > 0 else { return [] }
        let threshold = clusterThresholdShare * Double(peak)
        let candidates = hotRuns(buckets, threshold: threshold)
            .filter { $0.count >= minimumClusterLength }
            .map { makeCluster(buckets, range: $0, peak: peak) }
        let ranked = candidates.sorted { lhs, rhs in
            lhs.intensity == rhs.intensity
                ? lhs.startPercent < rhs.startPercent
                : lhs.intensity > rhs.intensity
        }
        return Array(ranked.prefix(limit))
    }
}

// MARK: - Run detection

private extension ReplayHeatAnalysis {
    /// Every maximal run of buckets at or above `threshold`, in positional order.
    ///
    /// Maximal by construction: a run only closes on a bucket below the threshold or
    /// at the end of the array, so no two returned ranges can be adjacent.
    static func hotRuns(_ buckets: [UInt32], threshold: Double) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var start: Int?
        for (index, count) in buckets.enumerated() {
            if Double(count) >= threshold {
                if start == nil { start = index }
            } else if let began = start {
                runs.append(began ..< index)
                start = nil
            }
        }
        if let began = start { runs.append(began ..< buckets.count) }
        return runs
    }

    static func makeCluster(_ buckets: [UInt32], range: Range<Int>, peak: UInt32) -> ReplayCluster {
        let sum = range.reduce(UInt64(0)) { $0 + UInt64(buckets[$1]) }
        let mean = Double(sum) / Double(range.count)
        return ReplayCluster(
            startPercent: range.lowerBound,
            endPercent: range.upperBound,
            intensity: StatsRounding.ratio(mean, over: Double(peak))
        )
    }
}
