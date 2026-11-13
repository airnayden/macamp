// AssistantViewModel+Hygiene — turns what the hygiene pass SAW into what the
// listener can ACCEPT.
//
// ── WHY THE MAPPING LIVES HERE AND NOT IN `Services` ───────────────────────────
//
// The analyzers produce `HygieneFinding`s; `AIProposal` lives in `ViewModels`. The
// layering is `Models → Persistence → Services → ViewModels`, so this direction is
// the only legal one: ViewModels imports Services, never the reverse. Putting the
// mapping in `Services` would need the proposal types down there, which would drag
// the whole propose/apply seam — including the `apply` that writes — beneath the
// layer that owns it.
//
// ── NO NEW PROPOSAL KIND WAS NEEDED ────────────────────────────────────────────
//
// All three findings fit the four kinds todo 17 shipped, so `AIProposal.swift` is
// untouched:
//
//   duplicate     -> .organize(playlistId:diff:)   one per affected playlist
//   genreCluster  -> .tagChangeSet(patches:)       one per cluster
//   metadataGap   -> .tagChangeSet(patches:)       ONE for the whole batch
//
// A "remove this membership" kind was considered and rejected: `.organize` already
// carries the complete post-change membership, which is exactly what the apply path
// writes (`reorder`, one transaction) — a narrower kind would describe the same
// write in a second vocabulary that a preview could disagree with.
//
// ── WHY GAPS MERGE AND CLUSTERS DO NOT ─────────────────────────────────────────
//
// Every gap patch says the same thing ("fill the album artist from the artist"), so
// N gap findings become ONE batch the listener confirms once — otherwise a library
// with three hundred untagged tracks would raise three hundred confirmation
// dialogs. Clusters do NOT merge: each names a different canonical spelling, so
// merging them would produce a single proposal whose headline could not say what it
// changes.
//
// Nothing here writes. These are proposals; `apply(_:confirmedBatch:)` remains the
// only code that touches a repository or a file, and every `tagChangeSet` produced
// here still requires `confirmedBatch: true`.
import Foundation
import Metadata
import Persistence
import Services

public extension AssistantViewModel {
    /// The proposals `findings` are actionable as, in a fixed order: the duplicate
    /// and cluster proposals in finding order, then one trailing batch for every
    /// metadata gap that carries a fix.
    ///
    /// PURE — reads nothing, files nothing. Findings with nothing to act on (a
    /// duplicate no playlist lists twice, a gap with no artist to copy) contribute
    /// no proposal, so the result can be shorter than `findings`, or empty.
    ///
    /// `nonisolated` so a caller off the main actor — and every helper below — can
    /// use it; a `static` member of a `@MainActor` type is otherwise isolated.
    nonisolated static func hygieneProposals(
        for findings: [HygieneFinding],
        profileId: Int64
    ) -> [AIProposal] {
        var proposals: [AIProposal] = []
        var gapPatches: [TagPatch] = []
        for finding in findings {
            switch finding {
            case let .duplicate(group):
                proposals.append(contentsOf: organizeProposals(for: group, profileId: profileId))
            case let .genreCluster(cluster):
                guard let proposal = retagProposal(for: cluster, profileId: profileId) else { continue }
                proposals.append(proposal)
            case let .metadataGap(gap):
                guard let patch = albumArtistPatch(for: gap) else { continue }
                gapPatches.append(patch)
            }
        }
        guard !gapPatches.isEmpty else { return proposals }
        return proposals + [AIProposal(profileId: profileId, kind: .tagChangeSet(patches: gapPatches))]
    }

    /// Maps `findings` and files the result in ``proposals``.
    ///
    /// Writes NOTHING — filing a proposal is inert by construction (``ProposalStore``
    /// cannot reach a repository). The listener still has to accept each one.
    @discardableResult
    func fileHygieneProposals(for findings: [HygieneFinding], profileId: Int64) -> [AIProposal] {
        let filed = Self.hygieneProposals(for: findings, profileId: profileId)
        for proposal in filed {
            proposals.add(proposal)
        }
        return filed
    }
}

// MARK: - Per-finding mapping

private extension AssistantViewModel {
    /// One `.organize` per playlist that lists the recording more than once.
    ///
    /// A group with no affected playlist maps to NOTHING: two copies on disk are not
    /// a change to propose, and this layer cannot propose deleting either file.
    nonisolated static func organizeProposals(
        for group: DuplicateGroup,
        profileId: Int64
    ) -> [AIProposal] {
        group.playlistCleanups.compactMap { cleanup in
            let diff = PlaylistOrganizeDiff(
                currentTrackIds: cleanup.currentTrackIds,
                proposedTrackIds: cleanup.proposedTrackIds
            )
            guard !diff.isEmpty else { return nil }
            return AIProposal(
                profileId: profileId,
                kind: .organize(playlistId: cleanup.playlistId, diff: diff)
            )
        }
    }

    /// One `.tagChangeSet` writing the canonical spelling onto every minority-spelled
    /// track. The tracks already carrying the canonical spelling are not patched —
    /// rewriting a tag to the value it already holds is a file write for nothing.
    nonisolated static func retagProposal(
        for cluster: GenreCluster,
        profileId: Int64
    ) -> AIProposal? {
        let patches = cluster.tracksToRetag.map { track in
            TagPatch(
                trackId: track.trackId,
                fileURL: track.fileURL,
                patch: WritableMetadata(genre: cluster.canonicalGenre)
            )
        }
        guard !patches.isEmpty else { return nil }
        return AIProposal(profileId: profileId, kind: .tagChangeSet(patches: patches))
    }

    /// The album-artist fill, or `nil` when the gap carries no derivable fix.
    ///
    /// `genre` and `year` gaps deliberately reach here and produce nothing: the
    /// analyzer has no local evidence for either, and a proposal that filled them
    /// would be putting a value on a file that nothing measured.
    nonisolated static func albumArtistPatch(for gap: MetadataGap) -> TagPatch? {
        guard let albumArtist = gap.suggestedAlbumArtist else { return nil }
        return TagPatch(
            trackId: gap.track.trackId,
            fileURL: gap.track.fileURL,
            patch: WritableMetadata(albumArtist: albumArtist)
        )
    }
}
