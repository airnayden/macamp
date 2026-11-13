import DesignSystem
import Foundation
@testable import MacAMP
import Persistence
import Testing
import ViewModels

/// The caption/tooltip that names the scrubber's replay curve must appear if and
/// only if the curve itself is drawing something. A "Most Replayed" label over an
/// empty scrubber names a shape that is not there.
@Suite("ScrubberHeatLabelTests")
struct ScrubberHeatLabelTests {
    // MARK: hasHeat — the same predicate the curve silences itself by

    @Test("no loaded row means no curve to name")
    func nilHeatHasNoContent() {
        #expect(ScrubberHeatLabel.hasHeat(nil) == false)
    }

    @Test("an empty intensity array means no curve to name")
    func emptyHeatHasNoContent() {
        #expect(ScrubberHeatLabel.hasHeat([]) == false)
    }

    @Test("a single bucket cannot span a curve")
    func singleBucketHasNoContent() {
        #expect(ScrubberHeatLabel.hasHeat([1]) == false)
    }

    @Test("an all-zero row draws nothing, so it names nothing")
    func allZeroHasNoContent() {
        #expect(ScrubberHeatLabel.hasHeat([0, 0, 0, 0]) == false)
    }

    @Test("a non-finite row draws nothing, so it names nothing")
    func nonFiniteHasNoContent() {
        #expect(ScrubberHeatLabel.hasHeat([.nan, .infinity]) == false)
    }

    @Test("a row with at least one positive bucket has a curve to name")
    func positiveBucketHasContent() {
        #expect(ScrubberHeatLabel.hasHeat([0, 0.5, 1]))
    }

    // MARK: isVisible — reveal AND content, never one alone

    /// The adversarial case: a hover over a track with NO heat must not caption an
    /// empty scrubber. Reveal alone is not evidence that a curve exists.
    @Test("revealed with no heat stays hidden")
    func revealedWithoutHeatStaysHidden() {
        #expect(ScrubberHeatLabel.isVisible(isRevealed: true, intensities: nil) == false)
        #expect(ScrubberHeatLabel.isVisible(isRevealed: true, intensities: []) == false)
        #expect(ScrubberHeatLabel.isVisible(isRevealed: true, intensities: [0, 0]) == false)
    }

    @Test("heat that is not revealed stays hidden")
    func unrevealedHeatStaysHidden() {
        #expect(ScrubberHeatLabel.isVisible(isRevealed: false, intensities: [0, 1]) == false)
    }

    @Test("revealed heat is captioned")
    func revealedHeatIsVisible() {
        #expect(ScrubberHeatLabel.isVisible(isRevealed: true, intensities: [0, 1]))
    }

    /// The overload the hosts actually call — they hold the verdict, not the row.
    /// It must agree with the intensity form on every combination, or a surface
    /// could caption what another one hides.
    @Test("both isVisible overloads answer identically")
    func overloadsAgree() {
        let rows: [[Float]?] = [nil, [], [0, 0], [0, 1]]
        for row in rows {
            for isRevealed in [true, false] {
                let byIntensities = ScrubberHeatLabel.isVisible(isRevealed: isRevealed, intensities: row)
                let byVerdict = ScrubberHeatLabel.isVisible(
                    isRevealed: isRevealed,
                    hasHeat: ScrubberHeatLabel.hasHeat(row)
                )
                #expect(byIntensities == byVerdict)
            }
        }
        #expect(ScrubberHeatLabel.isVisible(isRevealed: true, hasHeat: false) == false)
        #expect(ScrubberHeatLabel.isVisible(isRevealed: false, hasHeat: true) == false)
        #expect(ScrubberHeatLabel.isVisible(isRevealed: true, hasHeat: true))
    }

    // MARK: Parity with the curve

    /// The label must never disagree with `ReplayHeatCurve`'s own silence rule —
    /// they are two renderings of one fact, so they read the SAME predicate.
    @Test("label content agrees with the curve's own content gate")
    func labelAgreesWithCurveGate() {
        let rows: [[Float]] = [
            [],
            [1],
            [0, 0],
            [0, 0.25, 1],
            [.nan, .infinity],
            [0, .nan, 0.75],
        ]
        for row in rows {
            #expect(ScrubberHeatLabel.hasHeat(row) == ReplayHeatGeometry.hasContent(row))
        }
    }

    /// The producer's own gate feeds this one: a row the view model rejects as
    /// untrustworthy resolves to `nil`, and a `nil` row is never captioned.
    @Test("a row the view model rejects is never captioned")
    func untrustworthyRowIsNeverCaptioned() throws {
        let record = try makeHeatRecord(totalPasses: 1, peakBucketCount: 1)
        let normalized = ScrubberHeatViewModel.normalized(record)

        #expect(normalized == nil)
        #expect(ScrubberHeatLabel.isVisible(isRevealed: true, intensities: normalized) == false)
    }

    /// The converse, so the previous test cannot pass by rejecting everything: a row
    /// that clears the trust floor normalizes AND is captioned when revealed.
    @Test("a trustworthy row is captioned when revealed")
    func trustworthyRowIsCaptioned() throws {
        let record = try makeHeatRecord(totalPasses: 4, peakBucketCount: 4)
        let normalized = ScrubberHeatViewModel.normalized(record)

        #expect(normalized != nil)
        #expect(ScrubberHeatLabel.isVisible(isRevealed: true, intensities: normalized))
        #expect(ScrubberHeatLabel.isVisible(isRevealed: false, intensities: normalized) == false)
    }

    // MARK: Fixtures

    /// A heat row whose bucket 0 carries `peakBucketCount` listens.
    private func makeHeatRecord(totalPasses: Int, peakBucketCount: UInt32) throws -> PlaySegmentHeatRecord {
        var buckets = [UInt32](repeating: 0, count: PlaySegmentHeatRecord.bucketCount)
        buckets[0] = peakBucketCount
        let blob = try PlaySegmentHeatRecord.encodeBuckets(buckets)
        return PlaySegmentHeatRecord(
            profileId: ProfileRecord.guestID,
            trackId: 1,
            durationSeconds: 200,
            bucketCounts: blob,
            totalPasses: totalPasses,
            updatedAt: 0
        )
    }
}
