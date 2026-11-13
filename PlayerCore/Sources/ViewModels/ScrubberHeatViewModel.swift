// ScrubberHeatViewModel — the normalized replay heatmap behind a seek scrubber.
//
// Reads ONE `playSegmentHeat` row for (active profile, current track) through the
// v15 `PlaySegmentHeatRepositoryProviding` seam and republishes it as 0…1
// intensities `ReplayHeatCurve` can draw. Everything about the shape of the row —
// the 400-byte little-endian blob, the survivability snapshot — stays behind the
// repository; this layer only normalizes and gates.
//
// Two gates decide whether the overlay appears at all, and BOTH resolve to `nil`
// (draw nothing) rather than to a flat/empty curve:
//   * no row for this profile+track — the track was never played by this profile;
//   * the row fails ``ReplayHeatAnalysis/hasTrustworthyShape(totalPasses:buckets:)``
//     — the same noise floor the digest applies, so a shape nothing corroborates
//     never masquerades as a "most replayed" verdict.
//
// Refresh policy is deliberately coarse: the shell re-keys a `.task(id:)` on track
// OR profile change and calls `load`. There is no live mid-track refresh — the row
// is only written when a listen FLUSHES, so polling it during playback would burn
// reads to observe a value that cannot move. A profile switch stops playback
// anyway, so the profile half of the key is honest rather than defensive.
import Foundation
import Observation
import Persistence
import Services

/// Publishes the current track's replay heatmap as normalized 0…1 intensities.
@MainActor
@Observable
public final class ScrubberHeatViewModel {
    /// Committed listen passes that on their own make a row's shape trustworthy — a
    /// row below this still shows its curve when one slice was replayed enough (see
    /// ``ReplayHeatAnalysis/hasTrustworthyShape(totalPasses:buckets:)``).
    ///
    /// `nonisolated` because ``normalized(_:)-(PlaySegmentHeatRecord?)`` is a pure
    /// static that must be callable off the main actor; a bare `static let` on a
    /// `@MainActor` type inherits main-actor isolation.
    public nonisolated static let minimumPasses = ReplayHeatAnalysis.minimumTrustedPasses

    /// One value per relative bucket, scaled so the busiest bucket is exactly `1.0`.
    /// `nil` means "draw nothing" — no row, too few passes, or an unreadable blob.
    public private(set) var heat: [Float]?

    @ObservationIgnored private let repository: any PlaySegmentHeatRepositoryProviding

    /// Increments on every ``load(profileId:trackId:)`` so a slow read for a track
    /// the user already skipped past cannot overwrite the newer one's result.
    @ObservationIgnored private var generation = 0

    public init(repository: any PlaySegmentHeatRepositoryProviding) {
        self.repository = repository
    }

    /// Loads the heatmap for one profile + track, clearing the previous track's
    /// curve first so a stale shape is never shown against new audio.
    ///
    /// A `nil` or non-positive `trackId` (a non-library track) resolves to `nil`
    /// without touching the database. The read itself runs OFF the main actor: the
    /// repository requirement is a `nonisolated async` function, so awaiting it from
    /// here hops to the cooperative pool and the UI never blocks on GRDB.
    public func load(profileId: Int64, trackId: Int64?) async {
        generation &+= 1
        let token = generation
        apply(nil)
        guard let trackId, trackId > 0 else { return }
        let record = try? await repository.segmentHeat(profileId: profileId, trackId: trackId)
        guard token == generation else { return }
        apply(Self.normalized(record))
    }

    /// Drops the current curve — for a shell that stops playback without a track change.
    public func clear() {
        generation &+= 1
        apply(nil)
    }

    /// The gate + normalization in one pure step, so both can be asserted directly.
    ///
    /// The blob is decoded BEFORE the gate — the peak half of the floor is a fact
    /// about the buckets, so there is no ordering in which it can be checked without
    /// them, and decoding once is cheaper than decoding twice.
    public nonisolated static func normalized(_ record: PlaySegmentHeatRecord?) -> [Float]? {
        guard let record, let buckets = try? record.decodedBuckets() else { return nil }
        guard ReplayHeatAnalysis.hasTrustworthyShape(
            totalPasses: record.totalPasses,
            buckets: buckets
        ) else { return nil }
        return normalized(buckets)
    }

    /// Scales counts by their own maximum, so the busiest bucket is exactly `1.0`.
    ///
    /// Relative rather than absolute on purpose: the curve answers "which parts of
    /// THIS song do I replay", and an absolute scale would flatten every track that
    /// is not the user's single most-played one into an unreadable line. An all-zero
    /// row has no maximum to scale by and returns `nil`.
    public nonisolated static func normalized(_ buckets: [UInt32]) -> [Float]? {
        guard let peak = buckets.max(), peak > 0 else { return nil }
        let scale = Float(peak)
        return buckets.map { Float($0) / scale }
    }

    /// Equality-guarded per the macOS UI performance contract: `@Observable` fires on
    /// same-value writes, and this model sits under the 0.5 s scrubber tick.
    private func apply(_ next: [Float]?) {
        guard next != heat else { return }
        heat = next
    }
}
