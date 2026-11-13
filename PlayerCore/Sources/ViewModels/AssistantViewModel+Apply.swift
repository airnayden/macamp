// AssistantViewModel+Apply — the ONLY code in the AI feature that writes.
//
// Everything reachable from ``AssistantViewModel/submit(text:profileId:locale:)``
// is read-only; everything below is reached exclusively from an explicit,
// listener-initiated ``AssistantViewModel/apply(_:confirmedBatch:)``. Splitting
// the write routing into its own file keeps that boundary visible in the file
// list, not just in a doc comment.
//
// ── WHAT IS AND IS NOT TRANSACTIONAL ───────────────────────────────────────────
//
// Playlist writes ARE. Membership always goes through
// `PlaylistRepositoryProviding.reorder(playlistId:orderedTrackIds:)`, which
// deletes and re-inserts the whole list in ONE transaction — so a create never
// leaves a half-filled playlist, and a failed create is compensated by deleting
// the empty playlist it made (the `GeneratedPlaylistService` precedent).
//
// Tag writes ARE NOT, and cannot be: each file is its own atomic
// temp-copy-and-rename, and there is no transaction spanning several files. A
// batch that fails on the third patch leaves the first two written. That is why
// the failure is reported as ``AssistantProposalError/tagWriteFailed(trackId:reason:)``
// naming the exact track, and why the proposal STAYS in the store: re-applying is
// idempotent (the same patch produces the same tags), so retrying finishes the job
// rather than doubling it.
//
// ── WHY A FAILURE KEEPS THE PROPOSAL ───────────────────────────────────────────
//
// Removal happens only after the routed write returns. A transient failure — a
// locked file, an unmounted volume — must not cost the listener the proposal they
// were about to accept.
//
// ── SEAM ORDERING ──────────────────────────────────────────────────────────────
//
// ``AssistantViewModel/onPlaylistCreatedFromProposal`` fires LAST: after `create`,
// after the transactional `reorder`, and after the store removal. A consumer that
// flushes work into the new playlist from that callback therefore cannot have its
// writes erased by the `reorder` — because there is no `reorder` left to run. The
// mirror rule is that a throwing path fires NOTHING, so held work is never flushed
// into a playlist that was just deleted and will be re-created under a new id.
// ``AssistantViewModel/onProposalDiscarded`` is the other half: the proposal is
// gone and nothing was written, so whatever was held for it can be dropped.
import Foundation
import Metadata
import Persistence

public extension AssistantViewModel {
    /// Applies `proposal`, then removes it from the store.
    ///
    /// - Parameters:
    ///   - proposal: Must still be in ``proposals``; a stale handle throws
    ///     ``AssistantProposalError/unknownProposal(id:)`` rather than re-applying
    ///     something the listener already dealt with.
    ///   - confirmedBatch: MUST be `true` for
    ///     ``AIProposal/Kind/tagChangeSet(patches:)``. The UI passes `true` only
    ///     from the explicit confirmation dialog; the default `false` means a
    ///     call site that forgot writes nothing instead of rewriting tags.
    /// - Throws: ``AssistantProposalError``, or whatever the repository threw. The
    ///   proposal stays in the store on every throwing path.
    func apply(_ proposal: AIProposal, confirmedBatch: Bool = false) async throws {
        guard proposals.contains(id: proposal.id) else {
            throw AssistantProposalError.unknownProposal(id: proposal.id)
        }
        var createdPlaylistId: Int64?
        switch proposal.kind {
        case let .createPlaylist(request):
            createdPlaylistId = try await applyCreate(request, profileId: proposal.profileId)
        case let .organize(playlistId, diff):
            do {
                try await repositories.playlists.reorder(
                    playlistId: playlistId,
                    orderedTrackIds: diff.proposedTrackIds,
                    expectedTrackIds: diff.currentTrackIds
                )
            } catch let error as PlaylistMembershipError {
                switch error {
                case let .playlistNotFound(id): throw AssistantProposalError.playlistNotFound(id: id)
                case let .changed(id): throw AssistantProposalError.playlistChanged(id: id)
                }
            }
        case let .rename(playlistId, name):
            try await applyRename(playlistId: playlistId, name: name)
        case let .tagChangeSet(patches):
            guard confirmedBatch else { throw AssistantProposalError.batchNotConfirmed }
            try await applyTagPatches(patches)
        }
        proposals.remove(proposal)
        setLastError(nil)
        if let createdPlaylistId {
            onPlaylistCreatedFromProposal?(proposal.id, createdPlaylistId)
        }
    }

    /// Drops a proposal. Writes nothing, undoes nothing, contacts no repository.
    ///
    /// Announces the drop on ``onProposalDiscarded`` only when a proposal was
    /// actually removed, so discarding a handle the store no longer holds is
    /// silent — the seam reports removals, not requests.
    func discard(_ proposal: AIProposal) {
        guard proposals.contains(id: proposal.id) else { return }
        proposals.remove(proposal)
        onProposalDiscarded?(proposal.id)
    }
}

// MARK: - Routed writes

private extension AssistantViewModel {
    /// Creates the playlist, then fills it in ONE transactional membership write.
    ///
    /// A failed fill deletes the playlist it just created, so a rejected apply
    /// never leaves a named, empty playlist behind for the listener to clean up.
    ///
    /// - Returns: The created playlist's id, reached ONLY once the membership write
    ///   has landed — which is what lets the caller announce a create that is
    ///   genuinely complete rather than one that is merely named.
    func applyCreate(_ request: CreatePlaylistRequest, profileId: Int64) async throws -> Int64 {
        let playlist = try await repositories.playlists.create(
            named: request.name,
            profileId: profileId
        )
        guard let playlistId = playlist.id else {
            throw AssistantProposalError.playlistNotCreated
        }
        do {
            try await repositories.playlists.reorder(
                playlistId: playlistId,
                orderedTrackIds: request.orderedTrackIds
            )
        } catch {
            _ = try? await repositories.playlists.deletePlaylist(id: playlistId)
            throw error
        }
        return playlistId
    }

    func applyRename(playlistId: Int64, name: String) async throws {
        let playlists = repositories.playlists
        let existing = try await Task.detached(priority: .utility) {
            try playlists.fetchPlaylist(id: playlistId)
        }.value
        guard var record = existing else {
            throw AssistantProposalError.playlistNotFound(id: playlistId)
        }
        record.name = name
        try await playlists.update(record)
    }

    /// Writes each patch off the main actor, marking the file as a self-write
    /// FIRST so the folder watcher already knows to ignore the FSEvents change by
    /// the time the rename lands.
    func applyTagPatches(_ patches: [TagPatch]) async throws {
        guard let writer = repositories.metadataWriter else {
            throw AssistantProposalError.metadataWriterUnavailable
        }
        let registry = repositories.selfWriteRegistry
        try await Task.detached(priority: .utility) {
            for patch in patches {
                registry?.markSelfWrite(patch.fileURL)
                do {
                    try writer.writeMetadata(patch.patch, to: patch.fileURL)
                } catch {
                    throw AssistantProposalError.tagWriteFailed(
                        trackId: patch.trackId,
                        reason: String(describing: error)
                    )
                }
            }
        }.value
    }
}
