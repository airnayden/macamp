// PlaylistDraft — the result half of the mix generator.
//
// A draft is a PROPOSAL, not a playlist: nothing here has touched the database.
// Todo 9 materialises one into `playlistTrack` rows; todo 16 reads its name slot
// and aggregates to title it; todo 17 shows it in a preview before anything is
// written. Keeping the draft a pure value is what makes propose-and-preview
// possible at all.
//
// Every entry carries WHY it is in the list. A later naming or narrative pass
// needs "60 % of these came from co-session similarity to track 42" without
// re-running the query that produced them, and a preview UI needs to explain a
// surprising inclusion. Re-deriving provenance downstream would mean a second
// implementation of the scoring that could disagree with this one.
//
// The three flags — ``PlaylistDraft/underfilled``,
// ``PlaylistDraft/artistSpacingSatisfied`` and
// ``PlaylistDraft/energyArcApplied`` — report what the pipeline could NOT do.
// They are facts about the produced order, computed from the final entries, not
// promises made by the request.
import Foundation

/// Why a track is in a draft.
public enum MixProvenance: Sendable, Equatable, Hashable {
    /// Materialised by a smart playlist's rules.
    case rulesResult
    /// Played in the same sittings as the seed track.
    case coSession
    /// Merely resembles the seed — the cold-start similarity path.
    case metadataNeighbour
    /// Historically engaged with, then silent.
    case forgottenFavourite
    /// Settled in the library, never played.
    case neverPlayed
    /// A top track of the same civil month in an earlier year.
    case throwback
    /// A top track of this daypart.
    case daypart(Daypart)
}

/// One track's place in a draft, with the evidence that put it there.
public struct MixDraftEntry: Sendable, Equatable, Hashable {
    /// The library `track.id` being proposed.
    public var trackId: Int64

    /// Which pool contributed it.
    public var provenance: MixProvenance

    /// The source's own ranking score, carried through unchanged. Comparable
    /// only against other scores in the SAME draft — a co-session weight and a
    /// daypart play count are different units.
    public var score: Double

    /// The analysed energy used for arc ordering, or `nil` when the track has no
    /// `trackAudioFeature` row.
    public var energy: Double?

    public init(trackId: Int64, provenance: MixProvenance, score: Double, energy: Double? = nil) {
        self.trackId = trackId
        self.provenance = provenance
        self.score = score
        self.energy = energy
    }
}

/// The slot a naming pass fills in.
///
/// Deliberately NOT a name: this records only what the mix was asked for, so
/// todo 16 can title it either from a language model or from a deterministic
/// template without the generator having taken a position on which. It carries
/// no user-visible text, so nothing here needs localising.
public struct MixNameHint: Sendable, Equatable, Hashable {
    /// The source family the draft came from.
    public var sourceKind: MixSourceKind

    /// The seed track, for a similarity mix.
    public var seedTrackId: Int64?

    /// The RESOLVED daypart, for a daypart mix — a `nil` request has already
    /// been turned into the concrete bucket by the time a draft exists.
    public var daypart: Daypart?

    /// How many tracks the draft actually holds.
    public var trackCount: Int

    public init(
        sourceKind: MixSourceKind,
        trackCount: Int,
        seedTrackId: Int64? = nil,
        daypart: Daypart? = nil
    ) {
        self.sourceKind = sourceKind
        self.trackCount = trackCount
        self.seedTrackId = seedTrackId
        self.daypart = daypart
    }
}

/// An ordered, annotated track proposal — the output of ``MixGenerating``.
public struct PlaylistDraft: Sendable, Equatable {
    /// The proposed tracks, in playing order.
    public var entries: [MixDraftEntry]

    /// What a naming pass has to work with.
    public var nameHint: MixNameHint

    /// `true` when the candidate pool held fewer tracks than the spec asked for.
    ///
    /// The draft still contains every candidate that WAS available: a mix is
    /// never padded with duplicates or filler, so a caller that needs a full
    /// list must widen the source, not retry.
    public var underfilled: Bool

    /// `true` when no two adjacent-enough entries share an artist.
    ///
    /// `false` means the pool made the requested spacing impossible — ten tracks
    /// by two artists cannot be spaced three apart — and the order shown is the
    /// widest-gap compromise, or that energy-arc ordering (which runs last and
    /// wins) re-clustered an artist.
    public var artistSpacingSatisfied: Bool

    /// `true` when the entries were re-ordered into a rise → peak → fall energy
    /// shape. `false` means the constraint was off, the draft was too short, or
    /// too little of the pool has been analysed — in which case the entries keep
    /// their de-clumped rank order.
    public var energyArcApplied: Bool

    /// Summed duration of every entry whose length is known, in seconds.
    public var totalDuration: TimeInterval

    public init(
        entries: [MixDraftEntry],
        nameHint: MixNameHint,
        underfilled: Bool = false,
        artistSpacingSatisfied: Bool = true,
        energyArcApplied: Bool = false,
        totalDuration: TimeInterval = 0
    ) {
        self.entries = entries
        self.nameHint = nameHint
        self.underfilled = underfilled
        self.artistSpacingSatisfied = artistSpacingSatisfied
        self.energyArcApplied = energyArcApplied
        self.totalDuration = totalDuration
    }
}

public extension PlaylistDraft {
    /// The proposal as the id list a repository wants.
    var trackIds: [Int64] {
        entries.map(\.trackId)
    }

    /// Whether the generator found nothing at all.
    var isEmpty: Bool {
        entries.isEmpty
    }

    /// A draft with nothing in it — what an empty pool produces, and the neutral
    /// value a ``MixGenerating`` fake serves until a test scripts one.
    static func empty(sourceKind: MixSourceKind = .rulesResult) -> PlaylistDraft {
        PlaylistDraft(
            entries: [],
            nameHint: MixNameHint(sourceKind: sourceKind, trackCount: 0),
            underfilled: true
        )
    }
}
