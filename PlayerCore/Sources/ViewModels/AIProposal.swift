// AIProposal — the one currency every AI mutation in MacAMP travels in.
//
// PROPOSE, PREVIEW, THEN APPLY. No AI feature writes anything directly. It
// produces one of these, the listener sees it, and only an explicit
// ``AssistantViewModel/apply(_:confirmedBatch:)`` turns it into rows on disk. The
// rule is enforced by API SHAPE rather than by discipline: nothing in this file or
// in ``ProposalStore`` can reach a repository, and no method anywhere both
// generates and applies in one call.
//
// A proposal is a pure value with a STABLE id. The id is minted once at
// construction and never re-derived, so a preview sheet, a list row and the apply
// that follows all address the same object even as the store around it changes —
// and `discard` on one proposal can never remove a different one.
//
// This file imports only Foundation + Metadata + Persistence + Services; it MUST
// NOT import AppKit or UIKit (PlayerCore portability invariant).
import Foundation
import Metadata
import Persistence
import Services

// MARK: - Proposal

/// One reviewable, un-applied change the assistant is offering.
public struct AIProposal: Identifiable, Sendable, Equatable {
    /// What the proposal would do. Four kinds, each routed to exactly one
    /// repository seam by ``AssistantViewModel/apply(_:confirmedBatch:)``.
    public enum Kind: Sendable, Equatable {
        /// Create a new, ordinary playlist from a generated draft.
        ///
        /// Deliberately an ORDINARY playlist, not a `generatedPlaylist` row: those
        /// are for the two recurring auto-mix kinds `GeneratedPlaylistService`
        /// owns and refreshes on a TTL. A one-off request is a thing the listener
        /// asked for once, and refreshing it later would silently rewrite a list
        /// they curated.
        case createPlaylist(CreatePlaylistRequest)
        /// Rewrite an existing playlist's membership and order.
        case organize(playlistId: Int64, diff: PlaylistOrganizeDiff)
        /// Rename an existing playlist.
        case rename(playlistId: Int64, name: String)
        /// Patch tags on disk. The ONLY kind that needs a second confirmation.
        case tagChangeSet(patches: [TagPatch])
    }

    /// Minted once at construction; never recomputed. See the file header.
    public let id: UUID
    /// The profile this proposal was built for and would be applied to.
    public let profileId: Int64
    public let kind: Kind

    public init(id: UUID = UUID(), profileId: Int64, kind: Kind) {
        self.id = id
        self.profileId = profileId
        self.kind = kind
    }

    /// Whether applying this proposal requires `confirmedBatch: true`.
    ///
    /// A property of the PROPOSAL rather than a hidden rule inside `apply`, so the
    /// preview UI can decide whether to raise the extra confirmation dialog from
    /// the same fact the enforcement reads.
    public var requiresBatchConfirmation: Bool {
        if case .tagChangeSet = kind {
            return true
        }
        return false
    }

    /// How many library rows or files the proposal would touch — the number a
    /// preview headline shows.
    public var affectedCount: Int {
        switch kind {
        case let .createPlaylist(request): request.draft.entries.count
        case let .organize(_, diff): diff.proposedTrackIds.count
        case .rename: 1
        case let .tagChangeSet(patches): patches.count
        }
    }
}

// MARK: - Create

/// Everything needed to turn a generated draft into a playlist.
public struct CreatePlaylistRequest: Sendable, Equatable {
    /// The ordered, annotated track proposal.
    public var draft: PlaylistDraft
    /// The name to create the playlist under.
    ///
    /// GENERATED CONTENT IS DATA (the same rule ``PlaylistNamingResult`` states):
    /// this string is produced in the listener's own language at generation time
    /// and persisted into `playlist.name`, so it does not re-localize. Shells
    /// render it `Text(verbatim:)`.
    public var name: String
    /// An optional generated one-liner, same data rule as ``name``.
    public var summary: String?
    /// What the parser actually understood, when the proposal came from free text.
    ///
    /// Carried so a preview can answer "why these tracks?" — and so
    /// ``PlaylistQuerySpec/lowConfidence`` can be surfaced as "here's a starting
    /// point" rather than presenting a guess as an answer.
    public var querySpec: PlaylistQuerySpec?

    public init(
        draft: PlaylistDraft,
        name: String,
        summary: String? = nil,
        querySpec: PlaylistQuerySpec? = nil
    ) {
        self.draft = draft
        self.name = name
        self.summary = summary
        self.querySpec = querySpec
    }

    /// The draft's ids in playing order — what apply writes.
    public var orderedTrackIds: [Int64] {
        draft.trackIds
    }
}

// MARK: - Organize

/// A membership rewrite, expressed as both the final list and the difference
/// from the current one.
///
/// ``proposedTrackIds`` is the TRUTH — it is what apply writes, in one
/// transactional `reorder`. The three difference lists are derived from it by
/// ``init(currentTrackIds:proposedTrackIds:)`` so a preview can never describe a
/// change other than the one that will happen.
public struct PlaylistOrganizeDiff: Sendable, Equatable {
    /// The membership the diff was derived AGAINST, in current order.
    ///
    /// Retained rather than discarded after deriving the three lists below, because
    /// "leave this one track alone" (``excluding(trackIds:)``) is not expressible
    /// without it: the derived lists say a track moved, not where it moved FROM.
    public var currentTrackIds: [Int64]
    /// The complete membership after applying, in order.
    public var proposedTrackIds: [Int64]
    /// Ids not currently in the playlist, in proposed order.
    public var additions: [Int64]
    /// Ids currently in the playlist that the proposal drops, in current order.
    public var removals: [Int64]
    /// Ids present both before and after whose position changes, in proposed order.
    public var moves: [Int64]

    /// Derives the difference lists from the two memberships.
    ///
    /// Duplicate ids in either list are collapsed to their first occurrence:
    /// `playlistTrack` is positioned and a repeat cannot be materialised, so
    /// carrying one into a proposal would produce a diff the writer cannot honour.
    public init(currentTrackIds: [Int64], proposedTrackIds: [Int64]) {
        let current = Self.deduplicated(currentTrackIds)
        let proposed = Self.deduplicated(proposedTrackIds)
        let currentSet = Set(current)
        let proposedSet = Set(proposed)
        var currentIndex: [Int64: Int] = [:]
        for (index, trackId) in current.enumerated() {
            currentIndex[trackId] = index
        }
        self.currentTrackIds = current
        self.proposedTrackIds = proposed
        additions = proposed.filter { !currentSet.contains($0) }
        removals = current.filter { !proposedSet.contains($0) }
        moves = proposed.enumerated().compactMap { index, trackId in
            guard let was = currentIndex[trackId], was != index else { return nil }
            return trackId
        }
    }

    /// `true` when the proposal would change nothing.
    public var isEmpty: Bool {
        additions.isEmpty && removals.isEmpty && moves.isEmpty
    }

    private static func deduplicated(_ trackIds: [Int64]) -> [Int64] {
        var seen = Set<Int64>()
        return trackIds.filter { seen.insert($0).inserted }
    }
}

// MARK: - Tags

/// One track's tag patch, with the file it would be written to.
///
/// An ORDERED array of these rather than a `[Int64: WritableMetadata]` dictionary:
/// `Dictionary` iteration order is nondeterministic, so a dictionary would make
/// both the write order and any preview table vary run to run.
public struct TagPatch: Sendable, Equatable {
    /// The library row the patch belongs to, for preview and error reporting.
    public var trackId: Int64
    /// The file the tags are written to. Carried on the proposal so applying needs
    /// no second database round trip, and so the preview can show the file.
    public var fileURL: URL
    /// The fields to change. `nil` fields are left exactly as they are on disk.
    public var patch: WritableMetadata

    public init(trackId: Int64, fileURL: URL, patch: WritableMetadata) {
        self.trackId = trackId
        self.fileURL = fileURL
        self.patch = patch
    }
}

// MARK: - Errors

/// Why a proposal could not be produced or applied.
///
/// Repo-internal, so every switch over it must be exhaustive with no `default:`.
public enum AssistantProposalError: Error, Sendable, Equatable {
    /// A ``AIProposal/Kind/tagChangeSet(patches:)`` reached `apply` without
    /// `confirmedBatch: true`. Nothing was written.
    case batchNotConfirmed
    /// The proposal is not in the store — already applied, or discarded.
    case unknownProposal(id: UUID)
    /// The repository created a playlist but returned no id, so nothing could be
    /// written into it.
    case playlistNotCreated
    /// A rename or organize named a playlist that no longer exists.
    case playlistNotFound(id: Int64)
    /// The playlist changed since this suggestion's preview was created.
    case playlistChanged(id: Int64)
    /// A tag proposal was applied on a view model composed without a writer.
    case metadataWriterUnavailable
    /// A tag write failed. Earlier patches in the same batch may already be on
    /// disk — see ``AssistantViewModel/apply(_:confirmedBatch:)``.
    case tagWriteFailed(trackId: Int64, reason: String)
    /// The assistant is switched off or unusable; nothing was attempted.
    case assistantUnavailable(reason: AssistantUnavailableReason)
    /// The request was understood but selected no tracks the profile can play.
    case noMatchingTracks
    /// A read failed while building the proposal. Nothing was written — the whole
    /// generation path is read-only.
    case generationFailed(reason: String)
}
