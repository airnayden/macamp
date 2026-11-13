// ToolboxSeams — the two protocols the toolbox needs that nothing else in
// PlayerCore already provides.
//
// ── WHY `ToolboxProposalFiling` EXISTS AT ALL ─────────────────────────────────
//
// `AIProposal`, `ProposalStore` and `AssistantViewModel` all live in `ViewModels`,
// which sits ABOVE `Services` in the layering (`Models → Persistence → Services →
// ViewModels`). The toolbox lives in `Services`, so it cannot name any of them —
// the same constraint `AssistantViewModel+Hygiene.swift` records for the hygiene
// mapping, resolved the other way round: the mapping moved UP, this seam points
// DOWN. The composition root conforms this protocol over the proposal store; the
// toolbox only ever learns that a proposal was filed and what its id is.
//
// The requirement is `async` on purpose: `AssistantViewModel` is `@MainActor`, and
// an actor-isolated method can only witness a nonisolated protocol requirement
// when that requirement is `async`.
//
// ── AND WHY `ToolboxLibraryReading` EXISTS ────────────────────────────────────
//
// Three reads the tools need have no repository today: per-id audio features,
// genre counts, and a filtered sample. Rather than widen `TrackRepository` (whose
// surface is already large and consumed by every view model) they are gathered
// behind one narrow protocol with a production conformer over `AppDatabase`
// (``ToolboxLibraryReader``) and a fake in the test target — the repo's standard
// protocol-driven DI shape.
//
// This file imports Foundation + Persistence; it MUST NOT import AppKit, UIKit, or
// anything from `ViewModels` (PlayerCore portability + layering invariants).
import Foundation
import Persistence

// MARK: - Proposal filing

/// A "create this playlist" offer, filed for the listener to review.
///
/// Carries ids and display text only. No `filePath` appears here for the same
/// reason none appears in a rendered result: a proposal crosses into a model's
/// context, and the library's layout on disk is not the model's business.
public struct ToolboxPlaylistProposal: Sendable, Equatable {
    /// The profile the proposal belongs to.
    public var profileId: Int64
    /// The name to create the playlist under. Generated content is data — it does
    /// not re-localize (the same rule `CreatePlaylistRequest.name` states).
    public var name: String
    /// The membership, in the order the model asked for.
    public var trackIds: [Int64]
    /// An optional one-liner explaining the selection.
    public var summary: String?

    public init(profileId: Int64, name: String, trackIds: [Int64], summary: String? = nil) {
        self.profileId = profileId
        self.name = name
        self.trackIds = trackIds
        self.summary = summary
    }
}

/// Files a proposal for the listener to review. **Never applies one.**
public protocol ToolboxProposalFiling: Sendable {
    /// Files `proposal` and returns its stable id.
    ///
    /// The id is what the tool reports back, so a follow-up turn can refer to the
    /// offer the listener is looking at. Filing writes nothing to the library.
    func fileCreatePlaylistProposal(_ proposal: ToolboxPlaylistProposal) async throws -> UUID
}

// MARK: - Library reads

/// One genre and how many visible tracks carry it.
public struct ToolboxGenreCount: Sendable, Equatable, Hashable {
    /// The genre as stored, or `""` for the untagged bucket.
    public var name: String
    /// Visible tracks carrying it.
    public var trackCount: Int

    public init(name: String, trackCount: Int) {
        self.name = name
        self.trackCount = trackCount
    }
}

/// The bounds `sample_tracks` narrows the library by. Every field is optional;
/// all of them absent means "anything the profile can play".
public struct ToolboxSampleFilter: Sendable, Equatable, Hashable {
    /// Exact, case-insensitive genre match (the `tracksByGenre` convention).
    public var genre: String?
    /// Inclusive release-year bounds.
    public var minimumYear: Int?
    public var maximumYear: Int?
    /// Inclusive tempo bounds, in beats per minute.
    public var minimumTempo: Double?
    public var maximumTempo: Double?
    /// Inclusive energy bounds, normalised `0...1`.
    public var minimumEnergy: Double?
    public var maximumEnergy: Double?

    public init(
        genre: String? = nil,
        minimumYear: Int? = nil,
        maximumYear: Int? = nil,
        minimumTempo: Double? = nil,
        maximumTempo: Double? = nil,
        minimumEnergy: Double? = nil,
        maximumEnergy: Double? = nil
    ) {
        self.genre = genre
        self.minimumYear = minimumYear
        self.maximumYear = maximumYear
        self.minimumTempo = minimumTempo
        self.maximumTempo = maximumTempo
        self.minimumEnergy = minimumEnergy
        self.maximumEnergy = maximumEnergy
    }

    /// Whether the filter constrains nothing.
    public var isUnconstrained: Bool {
        self == ToolboxSampleFilter()
    }
}

/// The four profile-scoped reads the toolbox needs and no repository exposes.
public protocol ToolboxLibraryReading: Sendable {
    /// Cached analysis for the named tracks. A track with no row — or one that was
    /// never analysed — is simply absent from the result; the caller reports that
    /// as "not analysed" rather than as zeroes.
    func audioFeatures(trackIds: [Int64]) async throws -> [Int64: TrackAudioFeatureRecord]

    /// The named tracks that `profileId` can actually SEE, keyed by id.
    ///
    /// Deliberately not `TrackRepository.resolvedTracks(profileId:trackIds:)`,
    /// which applies no ``LibraryVisibility`` filter on purpose — a listening
    /// history has to keep rendering a track that has since left the profile's
    /// roots. A control tool asks the opposite question ("may this profile play
    /// this?"), so it needs the browse-surface predicate, and an id the profile
    /// cannot see must come back ABSENT rather than resolved.
    ///
    /// An absent id therefore means one of two indistinguishable things — no such
    /// row, or a row outside this profile's roots — and the caller says so in
    /// exactly those terms rather than guessing which.
    func visibleTracks(profileId: Int64, trackIds: [Int64]) async throws -> [Int64: TrackRecord]

    /// The profile's genre vocabulary with counts, busiest first then name
    /// ascending. The untagged bucket is reported as the empty name.
    func genreCounts(profileId: Int64, limit: Int) async throws -> [ToolboxGenreCount]

    /// Ids of visible, present tracks matching `filter`, bounded by `limit` and
    /// ordered deterministically. `now` is the evaluation instant.
    func sampleTrackIds(
        profileId: Int64,
        filter: ToolboxSampleFilter,
        limit: Int,
        now: Date
    ) async throws -> [Int64]
}
