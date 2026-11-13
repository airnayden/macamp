// ReplayHeatAnalysisTests — cluster detection and affinity on crafted bucket patterns.
//
// Each pattern below isolates one branch of the algorithm: nothing hot enough, one
// clear run, a lone hot bucket that must NOT become a cluster, two runs separated by a
// single cold bucket, a flat track where everything qualifies, and the boundary where
// a bucket sits exactly on the 60% threshold.
import Foundation
import Persistence
@testable import Services
import Testing

private func buckets(_ overrides: [Int: UInt32], baseline: UInt32 = 0) -> [UInt32] {
    var values = [UInt32](repeating: baseline, count: PlaySegmentHeatRecord.bucketCount)
    for (index, count) in overrides {
        values[index] = count
    }
    return values
}

@Suite("ReplayHeatAnalysis")
struct ReplayHeatAnalysisTests {
    // MARK: - Clusters

    @Test("an all-zero heatmap has no clusters and zero affinity")
    func emptyHeatmap() {
        let values = buckets([:])
        #expect(ReplayHeatAnalysis.clusters(values).isEmpty)
        #expect(ReplayHeatAnalysis.replayAffinity(values) == 0)
        #expect(ReplayHeatAnalysis.totalCount(values) == 0)
    }

    @Test("a single hot bucket is NOT a cluster — a passage needs two")
    func loneBucketIsNoCluster() {
        #expect(ReplayHeatAnalysis.clusters(buckets([40: 9], baseline: 1)).isEmpty)
    }

    @Test("two adjacent hot buckets are the shortest cluster")
    func shortestCluster() {
        let found = ReplayHeatAnalysis.clusters(buckets([40: 9, 41: 9], baseline: 1))
        #expect(found.count == 1)
        #expect(found.first?.startPercent == 40)
        #expect(found.first?.endPercent == 42)
        #expect(found.first?.intensity == 1)
    }

    @Test("a run is MAXIMAL — one cold bucket splits it into two")
    func coldBucketSplitsRuns() {
        // 20…22 hot, 23 cold, 24…25 hot: two runs, never one spanning the gap.
        let values = buckets([20: 10, 21: 10, 22: 10, 24: 8, 25: 8], baseline: 1)
        let found = ReplayHeatAnalysis.clusters(values)
        #expect(found.count == 2)
        #expect(found.map(\.startPercent) == [20, 24])
        #expect(found.map(\.endPercent) == [23, 26])
        // Ordered by intensity descending: 10/10 before 8/10.
        #expect(found.map(\.intensity) == [1, 0.8])
    }

    @Test("a run that reaches the last bucket still closes")
    func runAtTheEnd() {
        let found = ReplayHeatAnalysis.clusters(buckets([98: 5, 99: 5], baseline: 1))
        #expect(found.count == 1)
        #expect(found.first?.startPercent == 98)
        #expect(found.first?.endPercent == 100)
    }

    @Test("an all-equal heatmap is one cluster covering the whole track")
    func flatHeatmap() {
        let found = ReplayHeatAnalysis.clusters(DigestFixture.evenBuckets)
        #expect(found.count == 1)
        #expect(found.first?.startPercent == 0)
        #expect(found.first?.endPercent == 100)
        #expect(found.first?.intensity == 1)
    }

    @Test("a bucket exactly on the 60% threshold joins the cluster")
    func thresholdIsInclusive() {
        // Peak 10, threshold 6.0: a bucket of exactly 6 is in, 5 is out.
        let included = ReplayHeatAnalysis.clusters(buckets([10: 10, 11: 6], baseline: 1))
        #expect(included.count == 1)
        #expect(included.first?.endPercent == 12)
        let excluded = ReplayHeatAnalysis.clusters(buckets([10: 10, 11: 5], baseline: 1))
        #expect(excluded.isEmpty)
    }

    @Test("at most three clusters survive, the hottest first")
    func clusterLimit() {
        let values = buckets(
            [0: 10, 1: 10, 20: 9, 21: 9, 40: 8, 41: 8, 60: 7, 62: 7, 61: 7],
            baseline: 1
        )
        let found = ReplayHeatAnalysis.clusters(values)
        #expect(found.count == ReplayHeatAnalysis.clusterLimit)
        #expect(found.map(\.startPercent) == [0, 20, 40])
        #expect(found.map(\.intensity) == [1, 0.9, 0.8])
    }

    @Test("equally hot clusters fall back to position, so the order is total")
    func equalIntensityOrdersByPosition() {
        let found = ReplayHeatAnalysis.clusters(buckets([70: 4, 71: 4, 10: 4, 11: 4], baseline: 1))
        #expect(found.map(\.startPercent) == [10, 70])
    }

    @Test("intensity is the cluster mean over the peak, rounded to four places")
    func intensityIsAMean() {
        // Peak 10; a run of 10 and 7 means (10 + 7) / 2 / 10 = 0.85.
        let found = ReplayHeatAnalysis.clusters(buckets([30: 10, 31: 7], baseline: 1))
        #expect(found.first?.intensity == 0.85)
    }

    // MARK: - Affinity

    @Test("an even heatmap scores the floor: one decile of a hundred equal buckets")
    func evenAffinityIsTheFloor() {
        #expect(ReplayHeatAnalysis.replayAffinity(DigestFixture.evenBuckets) == 0.1)
    }

    @Test("looping one passage drives affinity far above the floor")
    func chorusAffinity() {
        // 93 buckets of 1, five of 10, two of 8 -> total 159; hottest ten sum to 69.
        let values = DigestFixture.chorusBuckets
        #expect(ReplayHeatAnalysis.totalCount(values) == 159)
        #expect(ReplayHeatAnalysis.replayAffinity(values) == 0.434)
    }

    @Test("affinity means the hottest ten BUCKETS, not the last ten percent")
    func affinityIsNotPositional() {
        // All the heat sits at the START of the track; a positional reading would
        // report the floor here instead of a near-total concentration.
        var values = [UInt32](repeating: 0, count: PlaySegmentHeatRecord.bucketCount)
        for index in 0 ..< 10 {
            values[index] = 100
        }
        #expect(ReplayHeatAnalysis.replayAffinity(values) == 1)
    }

    @Test("counts are summed as UInt64, so saturated buckets do not wrap")
    func widthOfTheSum() {
        let values = [UInt32](repeating: .max, count: PlaySegmentHeatRecord.bucketCount)
        #expect(ReplayHeatAnalysis.totalCount(values) == UInt64(UInt32.max) * 100)
        #expect(ReplayHeatAnalysis.replayAffinity(values) == 0.1)
    }

    // MARK: - The trust floor

    @Test("three committed sittings qualify, even when no slice was replayed")
    func threeSittingsQualify() {
        #expect(ReplayHeatAnalysis.hasTrustworthyShape(totalPasses: 3, buckets: buckets([:], baseline: 1)))
    }

    @Test("one sitting that replayed a passage four times qualifies")
    func oneSittingWithAReplayedPassageQualifies() {
        // The motivating case: a single long sitting with four rewinds to the same
        // passage. One flush means one pass, so the pass count alone hides it.
        #expect(ReplayHeatAnalysis.hasTrustworthyShape(totalPasses: 1, buckets: buckets([50: 4], baseline: 1)))
    }

    @Test("a peak of exactly three qualifies — the peak floor is inclusive")
    func peakFloorIsInclusive() {
        #expect(ReplayHeatAnalysis.hasTrustworthyShape(totalPasses: 1, buckets: buckets([50: 3], baseline: 1)))
    }

    @Test("one sitting whose busiest slice was heard twice clears neither half")
    func oneSittingBelowThePeakFloorIsHidden() {
        #expect(ReplayHeatAnalysis.hasTrustworthyShape(totalPasses: 1, buckets: buckets([50: 2], baseline: 1)) == false)
    }

    @Test("nothing played at all clears neither half")
    func emptyHeatmapIsNeverTrustworthy() {
        #expect(ReplayHeatAnalysis.hasTrustworthyShape(totalPasses: 0, buckets: buckets([:])) == false)
    }
}
