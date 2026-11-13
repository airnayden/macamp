// MixSpec — the request half of the mix generator.
//
// A spec says WHERE the candidates come from and WHAT SHAPE the result must have.
// It deliberately says nothing about how they are ranked: that is
// ``MixRanking``'s fixed pipeline, and keeping it out of the request is what lets
// two callers (todo 9's generated playlists, todo 14's assistant) ask for a mix
// without agreeing on an ordering policy first.
//
// Exactly ONE source feeds a mix. Blending two pools would require a common score
// scale — a co-session weight, a play count and a rule's rank position are not
// comparable numbers — and every caller in this plan generates per source kind
// anyway. A caller that wants a blend runs two specs and merges the drafts.
//
// The whole spec is a value: a `(spec, seed)` pair is the ONLY input to
// ``MixGeneratorService/generate(_:)``'s ordering, so the same pair always
// produces the same draft from the same library.
//
// NOT `Codable` on purpose. `generatedPlaylist.specJson` (todo 9) owns its own
// versioned wire format; making this type the persisted shape would freeze
// Swift's synthesized enum encoding — including the `_0` key it emits for an
// unlabelled payload — into stored rows.
import Foundation

/// Which of ``RediscoveryProviding``'s three lists feeds a mix.
public enum RediscoveryList: String, Sendable, Equatable, Hashable, CaseIterable {
    /// Historically engaged with, then silent for the whole silence window.
    case forgottenFavourites
    /// Settled in the library, never played.
    case neverPlayed
    /// Top tracks of the same civil month in earlier years.
    case throwbacks
}

/// Where a mix's candidate tracks come from.
public enum MixCandidateSource: Sendable, Equatable, Hashable {
    /// An already-ordered id list — normally a smart playlist's materialised
    /// result (``SmartPlaylistEvaluation/trackIds``).
    ///
    /// The generator takes the ids rather than a `playlistId` so that building a
    /// mix never triggers a materialisation as a side effect: evaluating rules
    /// rewrites `playlistTrack` rows, and a read-shaped call must not do that.
    /// The caller evaluates, then hands the result here.
    case rulesResult(trackIds: [Int64])

    /// Tracks the listener plays alongside one seed
    /// (``SimilarityProviding/similar(to:profileId:limit:)``).
    case similaritySeed(trackId: Int64)

    /// One rediscovery list for the profile.
    case rediscovery(list: RediscoveryList)

    /// The profile's tops for one daypart. `nil` means "whichever daypart it is
    /// now", resolved once at generation time through
    /// ``DaypartProviding/currentDaypart()`` so the draft records the concrete
    /// bucket it was built for.
    case daypart(part: Daypart?)
}

/// The source family a draft came from, flattened for the name slot.
public enum MixSourceKind: String, Sendable, Equatable, Hashable, CaseIterable {
    case rulesResult
    case similaritySeed
    case rediscovery
    case daypart
}

public extension MixCandidateSource {
    /// The flattened family, for provenance and naming.
    var kind: MixSourceKind {
        switch self {
        case .rulesResult: .rulesResult
        case .similaritySeed: .similaritySeed
        case .rediscovery: .rediscovery
        case .daypart: .daypart
        }
    }

    /// The seed track, when this source has one.
    var seedTrackId: Int64? {
        guard case let .similaritySeed(trackId) = self else { return nil }
        return trackId
    }

    /// The requested daypart, `nil` for every other source AND for the
    /// "current daypart" request that has not been resolved yet.
    var requestedDaypart: Daypart? {
        guard case let .daypart(part) = self else { return nil }
        return part
    }
}

/// The shape rules a draft must obey.
public struct MixConstraints: Sendable, Equatable, Hashable {
    /// Slots that must separate two tracks by the same artist. `3` means a
    /// repeat is allowed at `slot + 3` but not at `slot + 1` or `slot + 2`.
    /// `1` or less disables de-clumping entirely.
    public static let defaultArtistSpacing = 3

    /// Minimum separation between two tracks by the same artist.
    ///
    /// A pool that cannot satisfy it (ten tracks by two artists cannot be spaced
    /// three apart) degrades to the widest gap available rather than failing —
    /// ``PlaylistDraft/artistSpacingSatisfied`` reports which happened.
    public var artistSpacing: Int

    /// Whether to re-order the selection into a rise → peak → fall energy shape
    /// when enough of the pool has been analysed. Skipped silently otherwise.
    public var energyArc: Bool

    public init(artistSpacing: Int = defaultArtistSpacing, energyArc: Bool = true) {
        self.artistSpacing = artistSpacing
        self.energyArc = energyArc
    }
}

/// One request for a ranked mix.
public struct MixSpec: Sendable, Equatable, Hashable {
    /// Tracks a mix asks for when the caller does not say.
    public static let defaultTargetCount = 25

    /// Hard ceiling on ``targetCount``. Matches the insight services' own list
    /// ceilings (``RediscoveryService/maxLimit``, ``DaypartService/maxLimit``),
    /// so a larger request could not be served anyway.
    public static let maxTargetCount = 100

    /// The profile every candidate pool and every metadata read is scoped to.
    public var profileId: Int64

    /// The single pool the candidates are drawn from.
    public var source: MixCandidateSource

    /// How many tracks the draft should hold, clamped to `1 ... maxTargetCount`.
    /// A pool smaller than this yields a shorter, `underfilled` draft — never
    /// padding.
    public var targetCount: Int

    /// Total playing time to aim for, or `nil` to be governed by
    /// ``targetCount`` alone. Honoured to within one track: tracks are added in
    /// rank order until the next one would overshoot.
    public var targetDuration: TimeInterval?

    /// The de-clump and energy-arc rules.
    public var constraints: MixConstraints

    /// The seed for every pseudo-random decision in the pipeline — tie-breaks
    /// between equal scores, and therefore the whole ordering of a flat pool.
    /// Equal seeds over an unchanged library produce identical drafts.
    public var seed: UInt64

    public init(
        profileId: Int64,
        source: MixCandidateSource,
        targetCount: Int = defaultTargetCount,
        targetDuration: TimeInterval? = nil,
        constraints: MixConstraints = MixConstraints(),
        seed: UInt64 = 0
    ) {
        self.profileId = profileId
        self.source = source
        self.targetCount = min(max(1, targetCount), Self.maxTargetCount)
        self.targetDuration = targetDuration
        self.constraints = constraints
        self.seed = seed
    }
}
