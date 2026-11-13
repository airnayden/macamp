// MixRanking — the four pure steps between a candidate pool and a playing order.
//
// Nothing here touches a database, a clock or a global. Every step is a static
// function from values to values, so each can be asserted on its own and the
// service that chains them holds no ordering logic of its own:
//
//   1. SCORE ORDER    — highest source score first, exact ties broken by the
//                       injected generator. A pool whose scores are all equal
//                       (``RediscoveryProviding/neverPlayed(profileId:limit:)``
//                       is alphabetical, not ranked) therefore becomes a full
//                       seeded shuffle through the same mechanism, with no
//                       separate shuffle step to keep in sync.
//   2. DE-CLUMP       — greedy placement so the same artist does not recur
//                       within `spacing` slots, degrading to the widest gap
//                       available when the pool makes that impossible.
//   3. SELECT         — take the head that fits the target count and duration.
//                       This sits BETWEEN de-clump and arc on purpose: trimming
//                       an arc would cut off its fall and leave a mix that stops
//                       at its loudest point.
//   4. ENERGY ARC     — re-order into rise → peak → fall, but only when enough
//                       of the selection has been analysed.
//
// Step 4 runs last and therefore WINS where it conflicts with step 2: an arc is
// a property a listener hears across a whole mix, while a clump is a local
// annoyance, and re-spacing inside the arc would break the monotonicity that
// makes the arc worth having. ``PlaylistDraft/artistSpacingSatisfied`` is
// computed from the FINAL order, so a draft never claims a spacing it does not
// have.
//
// PlayerCore portability: Foundation only.
import Foundation

/// Deterministic `RandomNumberGenerator` (SplitMix64).
///
/// The mix pipeline seeds every pseudo-random decision through this generator so
/// a `(spec, seed)` pair reproduces byte for byte — which is what lets a preview
/// show the user the same mix the apply step will write.
///
/// The visualizer ships the same algorithm (`Visualizer/SeededGenerator.swift`)
/// for the same reason. It is duplicated rather than shared because `Services`
/// does not depend on `Visualizer` and inventing that edge to reuse ten lines of
/// arithmetic would be a worse trade than restating them.
public struct MixRandom: RandomNumberGenerator {
    private var state: UInt64

    /// Creates a generator seeded with `seed`. Equal seeds yield identical
    /// sequences across processes and platforms.
    public init(seed: UInt64) {
        state = seed
    }

    /// Returns the next 64-bit value and advances the internal state.
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var word = state
        word = (word ^ (word >> 30)) &* 0xBF58_476D_1CE4_E5B9
        word = (word ^ (word >> 27)) &* 0x94D0_49BB_1331_11EB
        return word ^ (word >> 31)
    }
}

/// One track under consideration, with everything the pipeline ranks on.
///
/// The three optional facts are filled in by ``MixCandidateResolving`` after the
/// source produced the pool: a source knows an id and a score, never a duration
/// or an energy. `nil` is a first-class value at every step — an untagged artist
/// never clumps, an unknown duration contributes nothing to the total, and an
/// unanalysed track is what the arc's coverage gate counts.
public struct MixCandidate: Sendable, Equatable, Hashable {
    /// The library `track.id`.
    public var trackId: Int64

    /// Which pool contributed it.
    public var provenance: MixProvenance

    /// The source's own ranking score. Higher ranks earlier.
    public var score: Double

    /// The de-clump identity — see ``MixTrackFacts/artistKey``. `nil` for an
    /// untagged track, which is then never treated as clumping.
    public var artistKey: String?

    /// Playing time in seconds, when known.
    public var duration: TimeInterval?

    /// Analysed energy (`0...1`), when a `trackAudioFeature` row exists.
    public var energy: Double?

    public init(
        trackId: Int64,
        provenance: MixProvenance,
        score: Double,
        artistKey: String? = nil,
        duration: TimeInterval? = nil,
        energy: Double? = nil
    ) {
        self.trackId = trackId
        self.provenance = provenance
        self.score = score
        self.artistKey = artistKey
        self.duration = duration
        self.energy = energy
    }
}

/// The pure ordering steps a mix goes through.
public enum MixRanking {
    /// Fraction of a selection that must carry an analysed energy before the arc
    /// is applied. Below it the arc would be shaped by the few analysed tracks
    /// and the rest would land wherever the fallback put them, which is worse
    /// than no arc at all.
    public static let energyArcCoverage = 0.8

    /// Shortest selection worth arcing. Two tracks cannot rise, peak and fall.
    public static let minimumArcLength = 3

    /// Step 1 — highest score first, exact ties broken by `generator`.
    ///
    /// The pool is pre-sorted by id before a single value is drawn, so the draw
    /// sequence is a property of the SET of candidates rather than of the order
    /// the source happened to page them in. Without that, two sources returning
    /// the same tracks in different orders would tie-break differently under the
    /// same seed.
    public static func scoreOrdered(
        _ candidates: [MixCandidate],
        using generator: inout some RandomNumberGenerator
    ) -> [MixCandidate] {
        let stable = candidates.sorted { $0.trackId < $1.trackId }
        var keyed: [(candidate: MixCandidate, tieBreak: UInt64)] = []
        keyed.reserveCapacity(stable.count)
        for candidate in stable {
            keyed.append((candidate, generator.next()))
        }
        keyed.sort { lhs, rhs in
            if lhs.candidate.score != rhs.candidate.score {
                return lhs.candidate.score > rhs.candidate.score
            }
            if lhs.tieBreak != rhs.tieBreak {
                return lhs.tieBreak < rhs.tieBreak
            }
            return lhs.candidate.trackId < rhs.candidate.trackId
        }
        return keyed.map(\.candidate)
    }

    /// Step 2 — re-order so the same artist does not recur within `spacing`
    /// slots, keeping the score order wherever the constraint allows.
    ///
    /// Greedy, one slot at a time: the highest-scoring remaining candidate whose
    /// artist is far enough back takes the slot. When NOTHING qualifies the slot
    /// goes to the candidate whose artist was placed longest ago (ties to the
    /// higher score) — the widest gap the pool can still offer. On the classic
    /// adversarial pool, ten tracks by two artists asked for spacing three, that
    /// rule produces strict alternation rather than the run of one artist a
    /// "keep the best-scoring one" compromise would give.
    ///
    /// Terminates in `O(n²)` comparisons: `remaining` loses exactly one element
    /// per slot regardless of which branch chose it.
    public static func deClumped(_ ordered: [MixCandidate], spacing: Int) -> [MixCandidate] {
        guard spacing > 1, ordered.count > 2 else { return ordered }
        var remaining = ordered
        var placed: [MixCandidate] = []
        placed.reserveCapacity(remaining.count)
        var lastSlot: [String: Int] = [:]
        while !remaining.isEmpty {
            let slot = placed.count
            let index = pickIndex(remaining, slot: slot, spacing: spacing, lastSlot: lastSlot)
            let chosen = remaining.remove(at: index)
            if let key = chosen.artistKey {
                lastSlot[key] = slot
            }
            placed.append(chosen)
        }
        return placed
    }

    /// Step 3 — the head of `ordered` that fits both targets.
    ///
    /// Tracks are added in rank order until the next one would overshoot
    /// `targetDuration`, which is what "honoured to within one track" means: the
    /// total never exceeds the target, and one more track always would. The
    /// first track is exempt so that a target shorter than any single track
    /// still yields a playable draft instead of an empty one.
    public static func selected(
        _ ordered: [MixCandidate],
        targetCount: Int,
        targetDuration: TimeInterval?
    ) -> [MixCandidate] {
        let ceiling = max(1, targetCount)
        var chosen: [MixCandidate] = []
        var total: TimeInterval = 0
        for candidate in ordered {
            guard chosen.count < ceiling else { break }
            let length = candidate.duration ?? 0
            if let targetDuration, !chosen.isEmpty, total + length > targetDuration { break }
            chosen.append(candidate)
            total += length
        }
        return chosen
    }

    /// Step 4 — rise → peak → fall by energy, or `nil` when the arc does not
    /// apply and the caller should keep the order it passed in.
    ///
    /// Built by sorting ascending and dealing alternately to the front and the
    /// back: `[1,2,3,4,5]` becomes `[1,3,5,4,2]`. That places the maximum in the
    /// middle and guarantees the two halves are monotone by construction, which
    /// a "sort each third" approach does not.
    ///
    /// Ties keep the incoming (de-clumped) order, so the arc inherits as much of
    /// step 2's spacing work as equal energies allow. An unanalysed track in an
    /// otherwise-analysed selection sorts at the pool's mean.
    public static func energyArced(_ ordered: [MixCandidate]) -> [MixCandidate]? {
        guard ordered.count >= minimumArcLength else { return nil }
        let known = ordered.compactMap(\.energy)
        guard !known.isEmpty, Double(known.count) / Double(ordered.count) >= energyArcCoverage else {
            return nil
        }
        let fallback = known.reduce(0, +) / Double(known.count)
        let ascending = ordered.enumerated().sorted { lhs, rhs in
            let left = lhs.element.energy ?? fallback
            let right = rhs.element.energy ?? fallback
            return left == right ? lhs.offset < rhs.offset : left < right
        }
        var rise: [MixCandidate] = []
        var fall: [MixCandidate] = []
        for (index, entry) in ascending.enumerated() {
            if index.isMultiple(of: 2) {
                rise.append(entry.element)
            } else {
                fall.append(entry.element)
            }
        }
        return rise + fall.reversed()
    }

    /// Whether `ordered` actually honours `spacing` — the fact
    /// ``PlaylistDraft/artistSpacingSatisfied`` publishes.
    public static func spacingSatisfied(_ ordered: [MixCandidate], spacing: Int) -> Bool {
        guard spacing > 1 else { return true }
        var lastSlot: [String: Int] = [:]
        for (slot, candidate) in ordered.enumerated() {
            guard let key = candidate.artistKey else { continue }
            if let last = lastSlot[key], slot - last < spacing { return false }
            lastSlot[key] = slot
        }
        return true
    }
}

private extension MixRanking {
    /// The index `deClumped` should place next: the first candidate that clears
    /// `spacing`, else the one whose artist was placed longest ago.
    static func pickIndex(
        _ remaining: [MixCandidate],
        slot: Int,
        spacing: Int,
        lastSlot: [String: Int]
    ) -> Int {
        var compromise = remaining.startIndex
        var widestGap = -1
        for index in remaining.indices {
            // An untagged artist, or one never placed, clears the constraint
            // trivially — and is the highest-scoring such candidate, because the
            // walk follows score order.
            guard let key = remaining[index].artistKey, let last = lastSlot[key] else { return index }
            let gap = slot - last
            if gap >= spacing { return index }
            if gap > widestGap {
                widestGap = gap
                compromise = index
            }
        }
        return compromise
    }
}
