// ProposalPreviewModel — the sheet's data and its apply state machine.
//
// WHY A MODEL AND NOT `@State` IN THE VIEW: resolving titles is a bounded database
// read that must run off the main actor, and the apply path has three outcomes the
// view has to render differently (in flight, failed-and-still-listed, applied). A
// view holding that in loose `@State` would re-run the read on every body pass.
//
// ── THE READ IS WINDOWED, AND CHUNKED BY HAND ──────────────────────────────────
//
// `TrackRepository.resolvedTracks` truncates anything past its own bound to a RANDOM
// prefix (`Set(trackIds).prefix(…)` — `Set` iteration order is nondeterministic), so
// a caller that leans on that bound gets an arbitrary subset back rather than an
// error. This type therefore chunks to ``idsPerBatch`` itself and caps the whole
// preview at ``maxResolvedIds``, which is deliberately the proposal ceiling: a draft
// filed at the maximum resolves every title, and anything past it is labelled as
// capped. Applying still uses the proposal's own, complete id list, which never
// passes through here.
//
// ── FAILURE KEEPS THE PROPOSAL ─────────────────────────────────────────────────
//
// `AssistantViewModel.apply` removes a proposal only after the routed write returns,
// so every throwing path leaves it in the store. This model mirrors that: a failure
// sets ``failure`` and returns `false`, the sheet stays open, and the listener can
// retry or discard. Nothing here ever calls `discard` on a failure.
//
// ── SELECTION IS AN EXCLUSION SET, NOT AN INCLUSION SET ────────────────────────
//
// Every track starts ticked, so the natural encoding is "which ones did the listener
// untick" — an empty ``excludedTrackIds`` is the default state and costs nothing,
// whereas materialising an inclusion set would mean building a 500-element `Set` for
// a sheet nobody has touched yet. It also makes the truncation rule fall out for
// free: an id the preview never listed can never be unticked, so it stays included
// exactly as ``AIProposal/excluding(trackIds:)`` documents.
import Foundation
import Metadata
import Observation
import Persistence
import SwiftUI
import ViewModels

@MainActor
@Observable
final class ProposalPreviewModel {
    /// Ids resolved per repository round trip — see the file header.
    static let idsPerBatch = 100
    /// Ceiling on how many titles the preview will resolve at all. Matches the
    /// proposal ceiling (`ToolResultBudget.proposalIdentifierLimit`), so a draft filed
    /// at the maximum still shows every title it named.
    static let maxResolvedIds = 500

    private(set) var titles: [Int64: String] = [:]
    private(set) var currentPlaylistName: String?
    private(set) var isLoading = false
    private(set) var isApplying = false
    private(set) var failure: LocalizedStringResource?
    /// `true` when the proposal names more tracks than ``maxResolvedIds``.
    private(set) var isTruncated = false
    /// The tracks the listener has UNTICKED. Empty means "apply everything".
    private(set) var excludedTrackIds: Set<Int64> = []

    func title(for trackId: Int64) -> String? {
        titles[trackId]
    }
}

// MARK: - Selection

extension ProposalPreviewModel {
    func isIncluded(_ trackId: Int64) -> Bool {
        !excludedTrackIds.contains(trackId)
    }

    func setIncluded(_ included: Bool, for trackId: Int64) {
        setIncluded(included, for: [trackId])
    }

    /// Ticks or unticks a whole section in one write, so a Select All over 100 rows
    /// invalidates observing views once instead of a hundred times.
    func setIncluded(_ included: Bool, for trackIds: [Int64]) {
        var updated = excludedTrackIds
        if included {
            updated.subtract(trackIds)
        } else {
            updated.formUnion(trackIds)
        }
        guard updated != excludedTrackIds else { return }
        excludedTrackIds = updated
    }

    /// The proposal narrowed to the ticked tracks — what Apply actually writes.
    func filtered(_ proposal: AIProposal) -> AIProposal {
        proposal.excluding(trackIds: excludedTrackIds)
    }

    func includedCount(in proposal: AIProposal) -> Int {
        filtered(proposal).affectedCount
    }

    /// Whether the narrowed proposal would still do anything.
    ///
    /// Exhaustive with no `default:`: a fifth kind must state what "nothing left to
    /// do" means for it. A rename is always actionable — it names no tracks, so the
    /// sheet shows no checkboxes and there is nothing to untick.
    static func isActionable(_ proposal: AIProposal) -> Bool {
        switch proposal.kind {
        case let .createPlaylist(request): !request.orderedTrackIds.isEmpty
        case let .organize(_, diff): !diff.isEmpty
        case .rename: true
        case let .tagChangeSet(patches): !patches.isEmpty
        }
    }

    /// Resolves display titles for everything the sheet lists, plus the current name
    /// a rename would replace. Runs once per presented proposal.
    func load(_ proposal: AIProposal, database: AppDatabase) async {
        guard !isLoading, titles.isEmpty, currentPlaylistName == nil else { return }
        isLoading = true
        defer { isLoading = false }
        await loadCurrentName(proposal, database: database)
        await loadTitles(proposal, database: database)
    }

    /// Applies the proposal — NARROWED to the ticked tracks — and reports whether the
    /// sheet may close.
    ///
    /// The narrowing happens here rather than at the call site so there is exactly one
    /// place the listener's selection can be forgotten, and it is this one. The
    /// filtered copy keeps the original id, so the store still recognises it.
    ///
    /// - Parameter confirmedBatch: `true` ONLY from the tag confirmation dialog's own
    ///   confirming button. Every other call site passes `false`, so a tag batch that
    ///   somehow reaches here unconfirmed writes nothing and reports
    ///   ``AssistantProposalError/batchNotConfirmed``.
    func apply(
        _ proposal: AIProposal,
        using assistant: AssistantViewModel,
        confirmedBatch: Bool
    ) async -> Bool {
        guard !isApplying else { return false }
        let narrowed = filtered(proposal)
        guard Self.isActionable(narrowed) else { return false }
        isApplying = true
        failure = nil
        defer { isApplying = false }
        do {
            try await assistant.apply(narrowed, confirmedBatch: confirmedBatch)
            return true
        } catch {
            failure = Self.message(for: error)
            return false
        }
    }
}

// MARK: - Failure copy

extension ProposalPreviewModel {
    /// Exhaustive over ``AssistantProposalError`` — the enum is repo-internal, so a
    /// new case must be given copy here before the shell compiles.
    static func message(for error: any Error) -> LocalizedStringResource {
        guard let proposalError = error as? AssistantProposalError else {
            return ProposalPreviewStrings.failureUnexpected
        }
        return proposalFailureMessage(proposalError)
    }

    private static func proposalFailureMessage(_ proposalError: AssistantProposalError) -> LocalizedStringResource {
        switch proposalError {
        case .batchNotConfirmed: ProposalPreviewStrings.failureBatchNotConfirmed
        case .unknownProposal: ProposalPreviewStrings.failureUnknownProposal
        case .playlistNotCreated: ProposalPreviewStrings.failurePlaylistNotCreated
        case .playlistNotFound: ProposalPreviewStrings.failurePlaylistNotFound
        case .playlistChanged: ProposalPreviewStrings.failurePlaylistChanged
        case .metadataWriterUnavailable: ProposalPreviewStrings.failureWriterUnavailable
        case .tagWriteFailed: ProposalPreviewStrings.failureTagWrite
        case let .assistantUnavailable(reason): reason.message
        case .noMatchingTracks: ProposalPreviewStrings.failureNoMatchingTracks
        case .generationFailed: ProposalPreviewStrings.failureGeneration
        }
    }
}

// MARK: - Bounded reads

private extension ProposalPreviewModel {
    func loadCurrentName(_ proposal: AIProposal, database: AppDatabase) async {
        guard case let .rename(playlistId, _) = proposal.kind else { return }
        let repository = PlaylistRepository(database)
        let record = try? await Task.detached(priority: .utility) {
            try repository.fetchPlaylist(id: playlistId)
        }.value
        currentPlaylistName = record?.name
    }

    func loadTitles(_ proposal: AIProposal, database: AppDatabase) async {
        let requested = Self.previewTrackIds(for: proposal)
        let bounded = Array(requested.prefix(Self.maxResolvedIds))
        isTruncated = requested.count > bounded.count
        guard !bounded.isEmpty else { return }
        let repository = TrackRepository(database)
        var resolved: [Int64: String] = [:]
        for batch in stride(from: 0, to: bounded.count, by: Self.idsPerBatch) {
            let upper = min(batch + Self.idsPerBatch, bounded.count)
            let chunk = Array(bounded[batch ..< upper])
            guard let rows = try? await repository.resolvedTracks(
                profileId: proposal.profileId,
                trackIds: chunk
            ) else { continue }
            for (trackId, row) in rows {
                resolved[trackId] = Self.displayTitle(for: row)
            }
        }
        titles = resolved
    }

    /// Every id the SHEET lists, de-duplicated and order-preserving. Never what
    /// apply writes — that comes off the proposal itself.
    static func previewTrackIds(for proposal: AIProposal) -> [Int64] {
        switch proposal.kind {
        case let .createPlaylist(request):
            deduplicated(request.orderedTrackIds)
        case let .organize(_, diff):
            deduplicated(diff.additions + diff.removals + diff.moves)
        case .rename:
            []
        case let .tagChangeSet(patches):
            deduplicated(patches.map(\.trackId))
        }
    }

    static func displayTitle(for row: ProfileScopedTrack) -> String {
        let title = row.track.title ?? URL(fileURLWithPath: row.track.filePath).lastPathComponent
        guard let artist = row.track.artistName, !artist.isEmpty else { return title }
        return "\(title) — \(artist)"
    }

    static func deduplicated(_ trackIds: [Int64]) -> [Int64] {
        var seen = Set<Int64>()
        return trackIds.filter { seen.insert($0).inserted }
    }
}
